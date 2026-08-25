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

   --  Number of physical cores, where the host says how its processors share
   --  them, and the processor count where it does not.
   --
   --  The two differ on a machine with simultaneous multithreading, where the
   --  operating system reports two processors for each core and they share one
   --  set of execution units. A worker on each of the two runs no faster than
   --  one worker on the core and costs twice the processor time, which is why
   --  the default worker count follows this rather than Processor_Count.
   --
   --  @return Core count, at least 1 and never above Processor_Count.
   function Core_Count return Positive;

   --  Whether this processor offers the wider vector instructions -- the
   --  per-lane variable shift and the gather -- that four of the fifteen
   --  quantized formats decode faster with.
   --
   --  False where the host says no and where it cannot be asked, which are
   --  the same answer to a caller: the baseline decoders run every format
   --  either way, and the four are between a third and four fifths slower
   --  without the instructions rather than wrong.
   --
   --  @return True only where the host says so plainly.
   function Wide_Vectors return Boolean;

   --  Whether this processor offers the byte dot product -- the instruction
   --  that multiplies four eight-bit pairs into one thirty-two bit lane.
   --
   --  A separate question from the one above and a narrower one: every
   --  processor that has this has the wider lanes as well, and the
   --  compilation reaching for it is built for the whole instruction set
   --  that carries it rather than the one instruction.
   --
   --  False where the host says no and where it cannot be asked. The
   --  sixteen-bit path computes the same products to the bound the
   --  conformance sweep states either way.
   --
   --  @return True only where the host says so plainly.
   function Byte_Products return Boolean;

   --  The host this build targets, as hostkit reports it.
   --
   --  Asked rather than inferred. The engine has one behaviour that differs
   --  by host -- whether the model file can be memory mapped -- and a reader
   --  told only "mapping unavailable" cannot tell a policy from a platform.
   --
   --  @return "linux", "macos", "windows", or "unsupported".
   function Host_Name return String;

end Model_Runner.Platform;
