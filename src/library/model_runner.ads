--  Local GGUF language-model execution engine.
--
--  Model_Runner loads a local GGUF model file, validates its container
--  strictly, prepares a bounded Llama-compatible decoder-only execution plan,
--  tokenizes prompts, evaluates the model on the CPU, maintains an explicit KV
--  cache, samples output tokens and streams decoded text.
--
--  Inference is local only. No package in this hierarchy opens a network
--  connection, spawns a process, or delegates evaluation to an external model
--  runtime.
--
--  Layering. Packages below Model_Runner.CLI and Model_Runner.Presentation
--  never write to standard output or standard error, never depend on the
--  message catalog, and never depend on terminal styling. They report
--  outcomes through Model_Runner.Errors.
package Model_Runner is
   pragma Pure;

   --  Semantic version of the model_runner crate. Kept identical to the
   --  version field of alire.toml; the repository checks in the tests crate
   --  verify that the two agree.
   Version : constant String := "0.1.0-dev";

   --  Repository license identifier reported by the version command.
   License : constant String := "MIT";

   --  Name used for the executable, the installed resource directory and the
   --  environment-variable prefix. Never localized.
   Program_Name : constant String := "model_runner";

end Model_Runner;
