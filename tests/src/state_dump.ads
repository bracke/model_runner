--  The stack's final states over a text, for training a block past it.
--
--  A model with no block that drafts the next token -- Mellum ships
--  without the one it was trained with -- can be given one trained here,
--  outside the program, on what the model itself does: at each position
--  of a text, the state the output head reads, the token there, and the
--  model's own few most likely next tokens with their log-probabilities.
--  A block that takes a state and the next token's embedding and is held
--  to the model's choice one further on is then drafting what the check
--  will keep.
--
--  The file is a run of records, one a text, little-endian:
--  the count N (32-bit), the width W (32-bit), the top count K (32-bit);
--  N tokens (32-bit); N rows of K token numbers (32-bit) and K
--  log-probabilities (binary32); N rows of W states (binary32).
--
--  Task safety: not task-safe; one run at a time.
with Model_Runner.Backend;

package State_Dump is

   --  What a run did.
   type Report is record
      Texts     : Natural := 0;
      Positions : Natural := 0;
      Failed    : Boolean := False;
   end record;

   --  Read each text through the model and append its records to Into.
   --
   --  @param Model Path of the model.
   --  @param Texts Paths of the texts, one a line, in a list file.
   --  @param Into Path of the file the records are written to, replaced.
   --  @param Backend Where the model runs.
   --  @param Top How many of the model's likeliest next tokens a position
   --    keeps.
   --  @param Most The most positions a text is read to.
   --  @param Round Whether the device's walks of a few positions round
   --    their activations to bytes, as run's default arithmetic has them.
   --  @param Result What was done.
   procedure Run
     (Model   : String;
      Texts   : String;
      Into    : String;
      Backend : Model_Runner.Backend.Backend_Kind;
      Top     : Positive;
      Most    : Positive;
      Result  : out Report;
      Round   : Boolean := False);

end State_Dump;
