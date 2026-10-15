--  Write a model out again in another format.
--
--  llama.cpp's `llama-quantize`, and the gap it fills is plain: this engine
--  reads twelve formats and wrote none. The encoders existed -- the fixture
--  builder has had them since it had fixtures -- but nothing turned a model
--  file into another model file, and nothing held an encoder to the rule the
--  format is defined by. See Quantizer for what that cost.
--
--  WHAT IT CONVERTS AND WHAT IT COPIES. What llama-quantize does, rule for
--  rule: a tensor its tensor_allows_quantization leaves alone -- a vector,
--  a norm, the router, a small convolution, a name not ending in "weight"
--  -- is copied as it stands; every other one gets the format asked for,
--  or the one a mixture gives it, and then tensor_type_fallback where its
--  rows will not divide into that format's blocks. A pure format therefore
--  writes Q5_0 on a 896-wide row asked for as Q4_K, as llama.cpp does with
--  --pure, and the keys that describe the quantizing are llama.cpp's.
--
--  IT IS WRITTEN AS IT GOES. The head first, from a plan of every tensor's
--  format and size, and then each tensor encoded on the heap and written:
--  the run holds one tensor, not the file.
--
--  THE CHECK IS THE OTHER IMPLEMENTATION. Two encoders that read the rules
--  the same way write the same bytes, searches and all. `--against` reads a
--  second file and compares the tensors they share, byte for byte, which is
--  a sharper question than any measurement of the result: not "is this
--  good" but "is this the same".
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

      --  How many of the converted ones the importance matrix weighted, and
      --  how many it did not -- not named, or a format (Q8_0, F16) the
      --  matrix does not change. A matrix that names none of them is a
      --  matrix for another model, and a run that said nothing about it
      --  would look like a run that used one.
      Weighted  : Natural := 0;
      Unweighted : Natural := 0;

      --  How many tensors a mixture gave something other than its base
      --  format, which is the whole of what a mixture is.
      Bumped    : Natural := 0;

      --  And the first tensor the two files do not even agree the shape of,
      --  which is a different fault from disagreeing about its bytes.
      First_Odd : String (1 .. 100) := [others => ' '];
      Odd_Up    : Natural := 0;

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
