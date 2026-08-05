with Model_Runner.CLI.Options;

--  Process entry point behind the executable.
--
--  The driver resolves the locale before anything can be reported, parses the
--  argument vector into a typed command, prepares the console and hands over
--  to command execution. It contains the outermost exception boundary: no
--  condition escapes it as an unhandled exception, and no Ada traceback ever
--  reaches a user.
package Model_Runner.CLI.Driver is

   --  Run the process from its own command line.
   --
   --  @param Status Process exit status.
   procedure Run_Process (Status : out Natural);

   --  Run from a supplied argument vector.
   --
   --  Exposed so that the tests crate can exercise the whole command path,
   --  including locale resolution and exit-status mapping, without a process.
   --
   --  @param Source Argument vector.
   --  @param Status Process exit status.
   procedure Run
     (Source : Model_Runner.CLI.Options.Arguments'Class;
      Status : out Natural);

end Model_Runner.CLI.Driver;
