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
   type Role is (System_Role, User_Role, Assistant_Role);

   --  Stable machine-readable role name, as a chat template spells it. Never
   --  localized: templates compare against these exact strings.
   --
   --  @param Item Role to name.
   --  @return "system", "user" or "assistant".
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

   --  Report whether the history begins with a system message.
   --
   --  @param Item History to inspect.
   --  @return True when message 1 is a system message.
   function Has_System (Item : History) return Boolean;

private

   Max_Messages : constant := 4096;

   type Message is record
      Sender : Role := User_Role;
      Offset : Natural := 0;
      Length : Natural := 0;
   end record;

   type Message_Array is array (1 .. Max_Messages) of Message;

   type Storage_Access is access String;

   type History is limited new Ada.Finalization.Limited_Controlled with record
      Bounds   : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Messages : Message_Array := [others => <>];
      Used     : Natural := 0;
      Storage  : Storage_Access := null;
      Filled   : Natural := 0;
   end record;

   overriding procedure Finalize (Item : in out History);

end Model_Runner.Conversation;
