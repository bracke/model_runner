--  A settings file of defaults, read once.
--
--  A caller who runs the same command with the same flags every time can
--  write those flags' values into a settings file instead. The file is
--  `key = value` a line, `#` a comment, and it is looked for at
--  MODEL_RUNNER_CONFIG, else <XDG_CONFIG_HOME or ~/.config>/model_runner/
--  config. Its keys are option names without the dashes -- backend,
--  kv-cache, threads, temperature -- and three that are not options:
--  models-dir, sessions-dir and hf-token, which the model search, the
--  session store and the hub token fall back to.
--
--  A command line flag overrides the file, and the file overrides a
--  built-in default; an environment variable overrides the file for the
--  three that have one. Nothing is written back; a missing or unreadable
--  file is simply no settings.
--
--  Task safety: loaded once on first use and read-only after; the first
--  use should be from one task.
package Model_Runner.Config is

   --  A setting's value, or the empty string when the file does not give it.
   --
   --  @param Key The setting name.
   --  @return The value, trimmed, or an empty string.
   function Value (Key : String) return String;

   --  Whether the file gives a setting.
   --
   --  @param Key The setting name.
   --  @return True when it is present.
   function Has (Key : String) return Boolean;

   --  How many settings the file gave, for a caller that walks them.
   --
   --  @return The count, zero where there is no file.
   function Count return Natural;

   --  The name of the setting at a position.
   --
   --  @param Index Position, from one to Count.
   --  @return The key.
   function Key_At (Index : Positive) return String;

   --  The value of the setting at a position.
   --
   --  @param Index Position, from one to Count.
   --  @return The value.
   function Value_At (Index : Positive) return String;

end Model_Runner.Config;
