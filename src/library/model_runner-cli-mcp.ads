with Ada.Strings.Unbounded;
with Model_Runner.Cancellation;

--  A conversation's Model Context Protocol servers: programs of the user's
--  that offer tools of their own. Each is named in the settings file as
--
--    mcp.NAME = COMMAND
--
--  and started by the host's shell in the session's folder, the protocol
--  spoken on its standard input and output, a JSON-RPC message a line. Its
--  tools are offered to the model as mcp__NAME__TOOL, described and shaped
--  as the server says; a call is sent to the server, and what it answers --
--  its text; a picture or other content said to be there -- is the tool's
--  answer. Every call is asked about first, as a shell's is, unless the
--  settings' tools.allow names it (mcp__NAME__* for all of a server's).
package Model_Runner.CLI.MCP is

   --  Whether the settings file names any server.
   function Configured return Boolean;

   --  Start the servers the settings file names and ask each for its
   --  tools, once a session: a server that will not start or answer is
   --  said in Notes, a line each, and not tried again.
   --
   --  @param Notes The servers that failed, and why; "" where none did.
   procedure Start_All (Notes : out Ada.Strings.Unbounded.Unbounded_String);

   --  The servers' tools as tool definitions, comma-separated -- the shape
   --  the built-in tools' are in -- or "" where there are none.
   function Definitions return String;

   --  Whether a tool is a server's.
   --
   --  @param Named The tool's name, as offered.
   function Owns (Named : String) return Boolean;

   --  How a call ended.
   type Call_End is (Answered, Failed, Cancelled, Timed_Out);

   --  Run a server's tool.
   --
   --  @param Named The tool's name, as offered.
   --  @param Arguments Its arguments, as JSON.
   --  @param Cancel Stops the wait, and asks the server to stop; or null.
   --  @param Said What it answered, or why it did not.
   --  @param Ended How it ended.
   procedure Call
     (Named     : String;
      Arguments : String;
      Cancel    : Model_Runner.Cancellation.Token_Reference;
      Said      : out Ada.Strings.Unbounded.Unbounded_String;
      Ended     : out Call_End);

   --  The servers, a line each: name, whether it runs, how many tools.
   function Listing return String;

   --  Let every server go.
   procedure Stop_All;

end Model_Runner.CLI.MCP;
