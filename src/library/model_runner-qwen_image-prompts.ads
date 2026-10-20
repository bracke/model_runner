with Model_Runner.Errors;
with Model_Runner.Llama;
with Model_Runner.Tensors;
with Model_Runner.Tokenizer;

--  The rows Qwen-Image 2.1's denoiser reads a prompt as: Qwen3-VL's state
--  of every token of it after the last layer, before the final norm
--  (docs/plan-image-generation.md, step 2).
--
--  The prompt is written into a raw template, not the chat template, and
--  the system turn's tokens -- counted by tokenizing that turn alone, as
--  the reference does -- are read and then dropped: they shape what
--  follows them, and the denoiser is given only what follows.
--
--  Task safety: one call at a time a model, which it opens a session of.
package Model_Runner.Qwen_Image.Prompts is

   --  What comes before the prompt, the system turn and the user's opening.
   System_Turn : constant String :=
     "<|im_start|>system" & ASCII.LF & "Comprehend and analyze the provided prompt.<|im_end|>" & ASCII.LF;

   --  The template the encoder reads.
   --
   --  @param Prompt what the picture is to be
   --  @return the prompt within its turns, the assistant's opened
   function Template (Prompt : String) return String
   is (System_Turn & "<|im_start|>user" & ASCII.LF & Prompt & "<|im_end|>" & ASCII.LF
       & "<|im_start|>assistant" & ASCII.LF);

   --  The longest prompt read, in tokens.
   Max_Tokens : constant := 4_096;

   --  Encode a prompt.
   --
   --  @param Encoder the text encoder, prepared
   --  @param Prompt what the picture is to be
   --  @param Rows the rows, Count of them, each the encoder's width, the
   --    system turn's dropped; null on failure
   --  @param Count how many
   --  @param Status success, or why not: the tokenizer's refusal, a prompt
   --    past Max_Tokens (Tokenizer_Input_Too_Long), or the session's
   procedure Encode
     (Encoder : in out Model_Runner.Llama.Model'Class;
      Prompt  : String;
      Rows    : out Model_Runner.Tensors.Real_Array_Access;
      Count   : out Natural;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Encode's reading, once the template is tokens: every token read,
   --  in as many batches as the encoder takes, and the rows of those
   --  after the first Dropped kept.
   --
   --  @param Encoder the text encoder, prepared
   --  @param Tokens the template's tokens
   --  @param Dropped how many of them the system turn is, read and not kept
   --  @param Rows Tokens'Length - Dropped rows, each the encoder's width;
   --    null on failure
   --  @param Status success, or the session's refusal
   procedure Rows_Of
     (Encoder : in out Model_Runner.Llama.Model'Class;
      Tokens  : Model_Runner.Tokenizer.Token_Array;
      Dropped : Natural;
      Rows    : out Model_Runner.Tensors.Real_Array_Access;
      Status  : out Model_Runner.Errors.Error_Info);

end Model_Runner.Qwen_Image.Prompts;
