with Model_Runner.Bytes;
with Model_Runner.Numerics;
with Model_Runner.GGUF;

--  The block formats' own encoding rules, as the reference implementation
--  states them.
--
--  This repository has had encoders since it had fixtures, and they are not
--  these. A fixture needs bytes a decoder will read, and any valid block
--  will do; `Fixtures.Encode_Four_Bit` scales a block from its minimum and
--  maximum and serves both Q4_0 and Q4_1 from that. THAT IS THE RULE FOR
--  Q4_1 AND IS NOT THE RULE FOR Q4_0, which tracks the largest magnitude and
--  keeps its sign:
--
--    if (amax < fabsf(v)) { amax = fabsf(v); max = v; }
--    const float d = max / -8;
--
--  A block of all-positive weights therefore gets a NEGATIVE scale, which a
--  minimum-and-maximum scheme can never produce. Nothing here noticed,
--  because the fixture check decodes what the encoder wrote: it holds the
--  decoder, and the encoder only has to be self-consistent. "Produces bytes
--  a Q4_0 reader accepts" is a weaker claim than "quantizes as Q4_0 is
--  defined", and until this package only the first one was made.
--
--  WHAT IS HERE. Five formats whose encoding is a closed-form rule -- Q8_0,
--  Q4_0, Q4_1, Q5_0 and Q5_1 -- and one that is not: Q6_K, whose scale for
--  each run of sixteen comes out of a SEARCH. Nineteen candidate inverse
--  scales are tried around the one the largest magnitude suggests, and the
--  one whose weighted least-squares fit is best is kept. Nothing about that
--  is closed form, and it is here because the question it raises is worth an
--  answer: two implementations that agree on the arithmetic can still part
--  company where two candidates are near-tied, and whether they do is a
--  measurement rather than a matter of opinion.
--
--  Q4_K searches too, and over a scale AND a minimum together: twenty-one
--  candidate inverse scales, each solving a weighted least-squares fit for
--  both at once and keeping whichever pair fits best. Q2_K, Q3_K and Q5_K
--  are the same family and are not here yet.
--
--  Every rule below is transcribed from `ggml/src/ggml-quants.c`, including
--  the parts that look like mistakes and are not: the truncation toward zero
--  after adding a half, which makes the rounding asymmetric about zero, and
--  the clamp on the high side only. A quantizer that rounded correctly would
--  produce better blocks and different files, and the point of this one is
--  to produce the same files.
--
--  Task safety: pure functions over arrays; no state.
package Quantizer is

   subtype Real_Array is Model_Runner.Numerics.Real_Array;
   subtype Byte_Array is Model_Runner.Bytes.Byte_Array;
   subtype Element_Count is Model_Runner.Numerics.Element_Count;

   --  The formats this can write.
   type Target is (Q8_0, Q4_0, Q4_1, Q5_0, Q5_1, Q4_K, Q6_K);

   --  Elements in one block. Thirty-two for the ones that carry a scale
   --  each, and a super-block of two hundred and fifty-six for the k-quant,
   --  which carries sixteen scales and a factor over them.
   --
   --  @param Item The format.
   --  @return Its block in elements.
   function Block_Of (Item : Target) return Element_Count
   is (case Item is
          when Q8_0 | Q4_0 | Q4_1 | Q5_0 | Q5_1 => 32,
          when Q4_K | Q6_K => 256);

   --  Bytes one block occupies.
   --
   --  @param Item The format.
   --  @return Its block size in bytes.
   function Bytes_Of (Item : Target) return Model_Runner.Bytes.Byte_Count
   is (case Item is
          when Q8_0 => 34,
          when Q4_0 => 18,
          when Q4_1 => 20,
          when Q5_0 => 22,
          when Q5_1 => 24,
          when Q4_K => 144,
          when Q6_K => 210);

   --  The tensor type each target writes, for the header to name.
   --
   --  @param Item The format.
   --  @return The type code a file names it by.
   function Type_Of (Item : Target) return Model_Runner.GGUF.Tensor_Type
   is (case Item is
          when Q8_0 => Model_Runner.GGUF.Type_Q8_0,
          when Q4_0 => Model_Runner.GGUF.Type_Q4_0,
          when Q4_1 => Model_Runner.GGUF.Type_Q4_1,
          when Q5_0 => Model_Runner.GGUF.Type_Q5_0,
          when Q5_1 => Model_Runner.GGUF.Type_Q5_1,
          when Q4_K => Model_Runner.GGUF.Type_Q4_K,
          when Q6_K => Model_Runner.GGUF.Type_Q6_K);

   --  Encode values into blocks of a format.
   --
   --  @param Values Values to encode, a whole number of blocks of them.
   --  @param Into Which format to write.
   --  @return The encoded bytes, indexed from zero.
   function Encode (Values : Real_Array; Into : Target) return Byte_Array;

   --  What a name says, or a name the caller mistyped.
   --
   --  @param Text A format's name, in any case.
   --  @param Item The format named.
   --  @param Known True when the name was one of them.
   procedure Named (Text : String; Item : out Target; Known : out Boolean);

   --  The name of a format, lower case, as the command takes it.
   --
   --  @param Item The format.
   --  @return Its name.
   function Name_Of (Item : Target) return String
   is (case Item is
          when Q8_0 => "q8_0",
          when Q4_0 => "q4_0",
          when Q4_1 => "q4_1",
          when Q5_0 => "q5_0",
          when Q5_1 => "q5_1",
          when Q4_K => "q4_k",
          when Q6_K => "q6_k");

end Quantizer;
