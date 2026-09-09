--  Collect an importance matrix by running a corpus through the model.
--
--  llama.cpp's `llama-imatrix`. For each weight matrix, the sum over the
--  corpus of the square of every activation that met each of its columns,
--  and beside it how many rows went into that sum. A quantizer given the
--  mean of those spends its levels where the model spends its attention;
--  `tests quantize --imatrix` is the other half and was built first, so
--  what this writes has somewhere exact to be judged.
--
--  WHERE THE NUMBERS COME FROM. Only the engine knows which matrix it is
--  about to read, so `Model_Runner.Llama.Watcher` is the seam: a session
--  hands every product's name and its vectors to something that wants them,
--  and this is that something. Nothing about the arithmetic changes; a run
--  that is not collecting pays a null check a product.
--
--  WHAT IT IS JUDGED BY. Not the file -- a file can be well-formed and
--  wrong -- but the bytes a quantizer writes from it. Ours and llama.cpp's
--  matrix over the same corpus should quantize the same model to the same
--  blocks, which is a question with one answer.
package Imatrix_Run is

   --  What one collection did.
   type Report is record
      Ran     : Boolean := False;
      Missing : Boolean := False;

      Detail    : String (1 .. 160) := [others => ' '];
      Detail_Up : Natural := 0;

      Tokens  : Natural := 0;
      Chunks  : Natural := 0;

      --  Matrices the run actually saw, which is not every matrix in the
      --  model: one an architecture never reaches is one no corpus can say
      --  anything about.
      Matrices : Natural := 0;

      Seconds : Duration := 0.0;
   end record;

   --  Run a corpus and write what it saw.
   --
   --  @param Path Model file to run.
   --  @param Text File holding the corpus.
   --  @param Chunk Tokens read in one pass.
   --  @param Chunks How many chunks to read, or zero for as many as there
   --    are.
   --  @param Threads Workers the products are divided across.
   --  @param Into Path to write the matrix to.
   --  @param Result What it did.
   procedure Run
     (Path    : String;
      Text    : String;
      Chunk   : Positive := 512;
      Chunks  : Natural := 0;
      Threads : Positive;
      Into    : String;
      Result  : out Report);

   --  One line saying what it did.
   --
   --  @param Item What Run did.
   --  @return The line.
   function Summary (Item : Report) return String;

end Imatrix_Run;
