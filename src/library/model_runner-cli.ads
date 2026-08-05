--  Command-line interface.
--
--  Status: not implemented in this build. The engine below this layer is
--  usable as a library -- Model_Runner.GGUF.Containers.Reader,
--  Model_Runner.Llama and Model_Runner.Tokenizer are complete and tested --
--  but no command has been implemented, and neither has the sampler, the
--  generation coordinator, the chat-template engine or the localized
--  presentation layer they depend on.
--
--  The driver therefore reports Internal_Not_Implemented rather than
--  succeeding silently, so that nothing in this repository behaves as though a
--  planned command already worked.
package Model_Runner.CLI is
end Model_Runner.CLI;
