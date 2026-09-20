with Interfaces;
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

   --  Path of the settings file.
   --
   --  MODEL_RUNNER_CONFIG names it outright; otherwise it is
   --  <XDG_CONFIG_HOME>/model_runner/config where that is set, and
   --  <HOME>/.config/model_runner/config where only HOME is. Empty when no
   --  home is known, and then there is no settings file.
   --
   --  @return The path, or an empty string when none is known.
   function Config_File return String;

   --  Directory the prefill cache is kept in.
   --
   --  <XDG_CACHE_HOME>/model_runner/prefill where that is set, else
   --  <HOME>/.cache/model_runner/prefill. Empty when no home is known,
   --  and then nothing is cached.
   --
   --  @return The directory, or an empty string when none is known.
   function Cache_Directory return String;

   --  A cache file path for a key -- the key hashed, under Cache_Directory.
   --  Empty when there is no cache directory. The same key gives the same
   --  path, so a run keys the file by the model and the settings that must
   --  match for a cache to be reused.
   --
   --  @param Key What the cache is for.
   --  @return The path, or an empty string when there is no directory.
   function Cache_File (Key : String) return String;

   --  Directory searched for a model named without a path.
   --
   --  MODEL_RUNNER_MODELS overrides it. Otherwise it is
   --  <XDG_DATA_HOME>/model_runner/models where that variable is set, and
   --  <HOME>/.local/share/model_runner/models where only HOME is. Empty
   --  when neither the override nor a home directory is known, which is
   --  when nothing is searched.
   --
   --  @return The directory, or an empty string when none is known.
   function Models_Directory return String;

   --  Resolve a model name a caller typed to the file to open.
   --
   --  A name that exists as given is returned unchanged, so an absolute
   --  path, a relative path, and a name in the current directory are read
   --  exactly as before. A bare name that the current directory does not
   --  hold is looked for in Models_Directory; found there, that path is
   --  returned. When neither has it the name is returned unchanged, so the
   --  failure that follows names what the caller typed.
   --
   --  @param Named The model path or name as given.
   --  @return The path to open.
   function Resolve_Model_Path (Named : String) return String;

   --  A path in the models directory for a file of this name, or an empty
   --  string when no models directory is known -- where a downloaded model
   --  is written so that a later run finds it by name.
   --
   --  @param Name The file name to place.
   --  @return The path, or an empty string when there is no directory.
   function Models_File (Name : String) return String;

   --  Directory a session named without a path is kept in.
   --
   --  MODEL_RUNNER_SESSIONS overrides it, and otherwise it sits beside the
   --  models, under model_runner's data home. Empty when no home is known.
   --
   --  @return The directory, or an empty string when none is known.
   function Sessions_Directory return String;

   --  Resolve a session name a caller typed to the file to read or write.
   --
   --  As with a model, a name that carries a path is taken as one. A bare
   --  name to load is read from the current directory where it is there,
   --  else from Sessions_Directory. A bare name to save is written into
   --  Sessions_Directory, so a name saved is a name loaded.
   --
   --  @param Named The session path or name as given.
   --  @param For_Saving True to resolve where it will be written, False to
   --    resolve where it is read from.
   --  @return The path to open.
   function Resolve_Session_Path
     (Named : String; For_Saving : Boolean) return String;

   --  Make the directory a path is written into, and its parents, where
   --  they are not there. A path in a directory that exists, and one the
   --  directory cannot be made for, are both left to the write to report.
   --
   --  @param Path The file about to be written.
   procedure Ensure_Parent_Directory (Path : String);

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

   --  Bytes of memory the host has, or zero where it will not say.
   --
   --  What the command bounds a session by when the caller names no
   --  limit: a model's declared context is a training fact and not a
   --  sizing one -- a forty-thousand-token context is eight gigabytes of
   --  cache on a thirty-billion-parameter mixture, held on the host and
   --  again on a device -- and a session that would take most of the
   --  machine is better refused with both numbers than started.
   --
   --  @return Bytes, or 0 when the host cannot be asked.
   function Physical_Memory return Interfaces.Unsigned_64;

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
