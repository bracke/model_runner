private with Ada.Finalization;

with Model_Runner.Errors;
with Model_Runner.Limits;

--  Structured conversation history.
--
--  A conversation is a sequence of messages, each with a role and content.
--  Nothing here stores a formatted string such as "User:": how a conversation
--  becomes a prompt is the template's decision, not the history's, and the
--  same history can be rendered by different templates.
--
--  Bounds. The message count and the total content size are bounded by the
--  session limits, so neither a long session nor a hostile input can make the
--  history grow without limit.
--
--  Privacy. Content is held in memory for the life of the history and is
--  cleared on Close. It is never written to disk by this package.
--
--  Task safety: a History is owned by one task.
package Model_Runner.Conversation is

   --  Who a message is from.
   --
   --  A tool message is what a caller hands back after the model asked for
   --  a tool: it is not the model speaking and it is not the person either,
   --  and a template that reads tools writes it differently from both --
   --  Qwen3 wraps it in <tool_response> and folds a run of them into one
   --  turn. Giving it a role of its own is what lets the template do that;
   --  handing the same text back as a user message would be a different
   --  conversation, rendered the same way for a model trained to tell them
   --  apart.
   type Role is (System_Role, User_Role, Assistant_Role, Tool_Role);

   --  Stable machine-readable role name, as a chat template spells it. Never
   --  localized: templates compare against these exact strings.
   --
   --  @param Item Role to name.
   --  @return "system", "user", "assistant" or "tool".
   function Role_Name (Item : Role) return String;

   --  A conversation. Release with Close, which is idempotent.
   type History is tagged limited private;

   --  Prepare an empty history.
   --
   --  @param Item History to open; released first.
   --  @param Bounds Session limits that bound the history.
   --  @param Status Success or Memory_Allocation_Failed.
   procedure Open
     (Item   : in out History;
      Bounds : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release a history and clear its content.
   --
   --  @param Item History to release.
   procedure Close (Item : in out History);

   --  Drop every message, keeping the allocated storage.
   --
   --  @param Item History to clear.
   procedure Clear (Item : in out History);

   --  Append a message.
   --
   --  @param Item History to extend.
   --  @param Sender Role of the message.
   --  @param Content Message text, UTF-8.
   --  @param Status Success, Conversation_Too_Long or Conversation_Empty when
   --    the content is empty.
   procedure Append
     (Item    : in out History;
      Sender  : Role;
      Content : String;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Append an assistant turn that asks for tools.
   --
   --  Its text may be empty where a plain message's may not: a model that
   --  answers with a call and nothing else said nothing, and the turn it
   --  said nothing in is still a turn. The calls it asks for follow, one
   --  Append_Call each.
   --
   --  @param Item History to extend.
   --  @param Content What the model said before it called, which may be
   --    nothing at all.
   --  @param Status Success or Conversation_Too_Long.
   procedure Append_Asking
     (Item    : in out History;
      Content : String;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Attach one tool call to the message appended last.
   --
   --  A call is kept beside the text rather than inside it. What the model
   --  wrote is one spelling of the call; a history that keeps that spelling
   --  hands the model its own words back, where a history that keeps the
   --  call lets the template write it again the way that model was trained
   --  to read it. Which is the whole difference between a conversation this
   --  engine understands and one it merely transcribes.
   --
   --  @param Item History to extend.
   --  @param Named The function the model called.
   --  @param Arguments The arguments, as one line of JSON.
   --  @param Status Success, Conversation_Empty when nothing has been
   --    appended for the call to belong to, or Conversation_Too_Long.
   procedure Append_Call
     (Item      : in out History;
      Named     : String;
      Arguments : String;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Append a model's reply as the turn it is.
   --
   --  A reply that asks for tools is what the model said and then the
   --  blocks it wrote its calls in. This takes the two apart: the text
   --  becomes the turn's content and each call is attached to it, so that
   --  the turn reaching the model again is written by the model's own
   --  template rather than pasted back in the model's own spelling.
   --
   --  For a reply to a model that was offered tools. A model offered none
   --  has no reason to write a call, and a reply that carries the words
   --  anyway is text: append that one.
   --
   --  @param Item History to extend.
   --  @param Reply What the model produced.
   --  @param Status Success, Conversation_Too_Long, or Conversation_Empty
   --    when the reply is empty and carries no call.
   --  @param Reading Whether the calls could be read. A block this cannot
   --    read leaves the reply appended whole, as text: a reply half taken
   --    apart is worse than one not taken apart at all, and the caller is
   --    told which of the two it has.
   procedure Append_Reply
     (Item    : in out History;
      Reply   : String;
      Status  : out Model_Runner.Errors.Error_Info;
      Reading : out Model_Runner.Errors.Error_Info);

   --  Set or replace the system message, which is always message 1.
   --
   --  Changing the system message invalidates every cached model position, so
   --  the caller resets the session afterwards.
   --
   --  @param Item History to update.
   --  @param Content System message text; an empty string removes it.
   --  @param Status Success or Conversation_Too_Long.
   procedure Set_System
     (Item    : in out History;
      Content : String;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Remove the last Count messages.
   --
   --  Used to drop a cancelled assistant turn so that the structured history
   --  never contains a response the model did not finish.
   --
   --  @param Item History to shorten.
   --  @param Count Number of trailing messages to remove.
   procedure Drop_Last (Item : in out History; Count : Natural);

   --  Number of messages.
   --
   --  @param Item History to inspect.
   --  @return Message count.
   function Length (Item : History) return Natural;

   --  Role of a message.
   --
   --  @param Item History to inspect.
   --  @param Index Message position in 1 .. Length.
   --  @return Role; User_Role when out of range.
   function Sender_At (Item : History; Index : Positive) return Role;

   --  Content of a message.
   --
   --  @param Item History to inspect.
   --  @param Index Message position in 1 .. Length.
   --  @return Message text, or an empty string when out of range.
   function Content_At (Item : History; Index : Positive) return String;

   --  How many tool calls a message asks for.
   --
   --  @param Item History to inspect.
   --  @param Index Message position in 1 .. Length.
   --  @return Call count; zero when the message asks for none and when the
   --    position is out of range.
   function Call_Count (Item : History; Index : Positive) return Natural;

   --  The function one call names.
   --
   --  @param Item History to inspect.
   --  @param Index Message position in 1 .. Length.
   --  @param Call Call position in 1 .. Call_Count.
   --  @return The name, or an empty string when either position is out of
   --    range.
   function Call_Name
     (Item : History; Index : Positive; Call : Positive) return String;

   --  The arguments one call carries.
   --
   --  @param Item History to inspect.
   --  @param Index Message position in 1 .. Length.
   --  @param Call Call position in 1 .. Call_Count.
   --  @return The arguments as one line of JSON, or an empty string when
   --    either position is out of range.
   function Call_Arguments
     (Item : History; Index : Positive; Call : Positive) return String;

   --  Report whether the history begins with a system message.
   --
   --  @param Item History to inspect.
   --  @return True when message 1 is a system message.
   function Has_System (Item : History) return Boolean;

private

   Max_Messages : constant := 4096;

   --  How many tool calls one history holds, over every message in it. A
   --  model asks for a handful at a time, and a table this size is a
   --  kilobyte beside a history whose content is bounded in megabytes.
   Max_Calls : constant := 256;

   type Message is record
      Sender : Role := User_Role;
      Offset : Natural := 0;
      Length : Natural := 0;

      --  Where this message's calls begin in the call table, and how many
      --  it has. They lie together because a call is only ever attached to
      --  the message appended last.
      First_Call : Natural := 0;
      Calls      : Natural := 0;
   end record;

   type Message_Array is array (1 .. Max_Messages) of Message;

   --  One call, as two slices of the same storage the content lies in: a
   --  call costs the room its text takes and no allocation of its own.
   type Call_Row is record
      Name_Offset : Natural := 0;
      Name_Length : Natural := 0;
      Args_Offset : Natural := 0;
      Args_Length : Natural := 0;
   end record;

   type Call_Array is array (1 .. Max_Calls) of Call_Row;

   type Storage_Access is access String;

   type History is limited new Ada.Finalization.Limited_Controlled with record
      Bounds   : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Messages : Message_Array := [others => <>];
      Used     : Natural := 0;
      Storage  : Storage_Access := null;
      Filled   : Natural := 0;
      Calls     : Call_Array := [others => <>];
      Call_Used : Natural := 0;
   end record;

   overriding procedure Finalize (Item : in out History);

end Model_Runner.Conversation;
