--  Write a model out again in another format.
--
--  llama.cpp's `llama-quantize`, and the gap it fills is plain: this engine
--  reads twelve formats and wrote none. The encoders existed -- the fixture
--  builder has had them since it had fixtures -- but nothing turned a model
--  file into another model file, and nothing held an encoder to the rule the
--  format is defined by. See Quantizer for what that cost.
--
--  WHAT IT CONVERTS AND WHAT IT COPIES. A tensor is re-encoded when its
--  element count is a whole number of blocks and it has more than one
--  dimension; everything else is copied as it stands, which is the norms and
--  the biases. That is a rule of this tool and not llama.cpp's policy, which
--  also holds particular tensors -- the output projection, the token
--  embedding -- at a higher precision than the name on the file. A file this
--  writes is therefore the format it says all the way through, and a file
--  llama.cpp writes is not; the two are worth comparing tensor by tensor
--  rather than as wholes, which is what --against does.
--
--  THE CHECK IS THE OTHER IMPLEMENTATION. The rule for these five formats is
--  a rule and not a search, so two encoders that read it the same way write
--  the same bytes. `--against` reads a second file and compares the tensors
--  they share, byte for byte, which is a sharper question than any
--  measurement of the result: not "is this good" but "is this the same".
package Quantize_Run is

   --  What one run did.
   type Report is record
      Ran     : Boolean := False;
      Missing : Boolean := False;

      Detail    : String (1 .. 160) := [others => ' '];
      Detail_Up : Natural := 0;

      Tensors   : Natural := 0;
      Converted : Natural := 0;
      Copied    : Natural := 0;

      --  How many of the converted ones the importance matrix named, and
      --  how many it did not. A matrix that names none of them is a matrix
      --  for another model, and a run that said nothing about it would look
      --  like a run that used one.
      Weighted  : Natural := 0;
      Unweighted : Natural := 0;

      Bytes_In  : Long_Long_Integer := 0;
      Bytes_Out : Long_Long_Integer := 0;

      --  Set only when a file was compared against.
      Compared  : Boolean := False;
      Same      : Natural := 0;
      Differing : Natural := 0;
      Absent    : Natural := 0;

      --  The first tensor whose bytes differ, and how many of its bytes do.
      First_Apart : String (1 .. 80) := [others => ' '];
      First_Up    : Natural := 0;
      Apart_Bytes : Long_Long_Integer := 0;

      --  And across every tensor, which is what says whether a difference
      --  is a disagreement about the rule or a handful of near-ties.
      Apart_Total : Long_Long_Integer := 0;

      Seconds : Duration := 0.0;
   end record;

   --  Read a model and write it out in another format.
   --
   --  @param Path Model file to read.
   --  @param Format Format to write, by name.
   --  @param Into Path to write, or the empty string to write nothing --
   --    which is what a caller comparing two files that already exist wants.
   --  @param Against A file to compare the tensors against, or empty.
   --  @param Matrix An importance matrix, as llama-imatrix writes one, or
   --    the empty string for none. A tensor the matrix does not name is
   --    quantized plainly, and how many were is in the report.
   --  @param Result What it did.
   procedure Run
     (Path    : String;
      Format  : String;
      Into    : String;
      Against : String;
      Matrix  : String;
      Result  : out Report);

   --  One line saying what it did.
   --
   --  @param Item What Run did.
   --  @return The line.
   function Summary (Item : Report) return String;

end Quantize_Run;
