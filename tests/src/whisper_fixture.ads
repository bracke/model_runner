with Model_Runner.Bytes;

--  A Whisper file small enough to build in a test: the profile's every key
--  and tensor, a model eight wide with two heads, one block a side, a feed-
--  forward of sixteen, eighty Mel filters, and a vocabulary of the 256 byte
--  tokens, the special tokens a multilingual model has (two languages, en
--  and da) and the 1,501 times. The weights are a fixed sequence, not
--  trained: what it says is noise, and what it is for is the loader, the
--  lifecycle and the arithmetic's shapes. Whether the arithmetic is the
--  reference's is held on the real models (tests hear --reference).
package Whisper_Fixture is

   --  What to get wrong, to see it refused.
   type Flaw is
     (None,
      Other_Architecture,
      Other_Profile,
      Missing_Tensor,
      Misshapen_Tensor,
      Token_Past_Vocabulary,
      Vocabulary_Mismatch,
      Too_Many_Blocks);

   --  Build the file.
   --
   --  @param Result Newly allocated bytes; the caller frees them.
   --  @param Defect What to get wrong.
   procedure Build (Result : out Model_Runner.Bytes.Byte_Array_Access; Defect : Flaw := None);

   --  Write it to a file.
   --
   --  @param Path The file; replaced.
   --  @param Defect What to get wrong.
   procedure Write (Path : String; Defect : Flaw := None);

end Whisper_Fixture;
