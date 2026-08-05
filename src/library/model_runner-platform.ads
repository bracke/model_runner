--  Host services used by the presentation layer and the model loader.
--
--  This is the only part of the crate that talks to the operating system
--  beyond ordinary file input and output. It is deliberately small so that the
--  rest of the crate stays portable and testable: terminal detection, locale
--  discovery, environment access, executable location and read-only file
--  mapping.
--
--  Nothing here opens a network connection or starts a process.
--
--  Task safety: the operations are stateless queries and may be called from
--  any task.
package Model_Runner.Platform is

   --  Report whether a standard stream is connected to a terminal.
   --
   --  @param Descriptor 0 for standard input, 1 for standard output, 2 for
   --    standard error.
   --  @return True when the descriptor refers to a terminal.
   function Is_Terminal (Descriptor : Natural) return Boolean;

   --  Report whether the NO_COLOR convention is active.
   --
   --  @return True when NO_COLOR is present in the environment.
   function No_Color_Requested return Boolean;

   --  Read an environment variable.
   --
   --  @param Name Variable name.
   --  @return Value, or an empty string when the variable is absent.
   function Environment_Value (Name : String) return String;

   --  Report whether an environment variable is present.
   --
   --  @param Name Variable name.
   --  @return True when the variable exists, even when its value is empty.
   function Environment_Exists (Name : String) return Boolean;

   --  Locale reported by the host, derived from LC_ALL then LANG.
   --
   --  @return Locale identifier, or an empty string when none is set.
   function Host_Locale return String;

   --  Directory containing the running executable.
   --
   --  @return Absolute directory path, or an empty string when it cannot be
   --    determined.
   function Executable_Directory return String;

   --  Path of the message catalog.
   --
   --  Searched relative to the running executable first, so an installed copy
   --  works from any working directory, then relative to the current
   --  directory for a development tree.
   --
   --  @return Catalog path; the conventional relative path when none exists.
   function Catalog_Path return String;

   --  Number of processors usable by this process.
   --
   --  @return Processor count, at least 1.
   function Processor_Count return Positive;

end Model_Runner.Platform;
