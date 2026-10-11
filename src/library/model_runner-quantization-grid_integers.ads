with Interfaces;

with Model_Runner.Bytes;
with Model_Runner.GGUF;
with Model_Runner.Numerics;

--  The grid formats' super-blocks as signed bytes and lane factors, for an
--  integer product.
--
--  A grid format's weight is a grid entry's byte, signed and scaled; the
--  scale is per sixteen or thirty-two elements and always a whole number
--  times the block's half -- (2s + 1)/8 for the two-bit grids, (2s + 1)/4
--  for IQ3_XXS, 2s + 1 for IQ3_S -- and IQ1's offset of an eighth comes out
--  whole at eight times: 8g + 1 or 8g - 1, so every weight is a byte and
--  the rest is a factor per four elements, which is what one lane of a byte
--  dot product sums. Decoding a super-block once, eight elements a table
--  read, and then taking byte dot products against each activation is how
--  llama.cpp's grid kernels go; the floating-point path widened every
--  weight to binary32 and ran thirty times slower.
--
--  Task safety: tables built once at elaboration, then read only.
private package Model_Runner.Quantization.Grid_Integers is

   --  Whether Format is one of the seven grid formats.
   --
   --  @param Format A weight format.
   --  @return True for IQ1_S, IQ1_M, IQ2_XXS, IQ2_XS, IQ2_S, IQ3_XXS and IQ3_S.
   function Is_Grid (Format : Model_Runner.GGUF.Tensor_Type) return Boolean;

   --  One super-block's two hundred and fifty-six weights, eight bytes to a
   --  word, element 8W + J in byte J of word W.
   type Word_Block is array (0 .. 31) of Interfaces.Unsigned_64
     with Alignment => 32;

   --  And its factors: element E's weight is its byte times Lanes (E / 4).
   type Lane_Block is array (0 .. 63) of Model_Runner.Numerics.Real
     with Alignment => 32;

   --  Decode one super-block.
   --
   --  @param Format A grid format.
   --  @param Data Buffer holding the block.
   --  @param Offset Byte position of the block, from Data'First; the whole
   --    block lies inside Data.
   --  @param Words Receives the weights as bytes.
   --  @param Lanes Receives the factor of each four.
   procedure Decode
     (Format : Model_Runner.GGUF.Tensor_Type;
      Data   : Model_Runner.Bytes.Byte_Array;
      Offset : Model_Runner.Bytes.Byte_Count;
      Words  : out Word_Block;
      Lanes  : out Lane_Block);

end Model_Runner.Quantization.Grid_Integers;
