--  A language server's word on a file the model changed.
--
--  Where the settings file names one (lsp = COMMAND, as
--  lsp = ada_language_server), it is started by the host's shell the
--  first time it is needed, rooted where the session is, and after each
--  write or edit it is given the file's text; the problems it publishes for
--  it -- line, severity, message -- go after the tool's answer, so the model
--  reads them as it would a compiler's.
--
--  The Language Server Protocol over the server's own standard input and
--  output: framed messages, initialize and initialized, didOpen once and
--  didChange after, a request the server makes answered with nothing so it
--  does not wait, shutdown and exit at the end.
--
--  Task safety: one server, used from the conversation's own task.
package Model_Runner.CLI.Language_Server is

   --  Whether the settings file names a language server.
   --
   --  @return True when a language server is configured.
   function Configured return Boolean;

   --  The problems the server finds in a file, as it now is: a line each,
   --  "line N: error: words"; "(none)" where it finds none; "" where there
   --  is no server or it said nothing about the file in Wait.
   --
   --  @param Path The file, as a full path.
   --  @param Wait How long its word is waited for.
   --  @return The problems.
   function Problems_In (Path : String; Wait : Duration := 8.0) return String;

   --  The server asked to stop, and let go of.
   procedure Stop;

end Model_Runner.CLI.Language_Server;
