with Interfaces;
with System;

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

   --  For a kernel that decodes in its registers: where the tables are.
   --  The grids as the format keeps them; the two-bit grids' seven-bit sign
   --  indices, and a sign byte itself, as eight bytes of +1 or -1, what a
   --  byte sign instruction reads; and IQ1's offset, +1 or -1 in eight
   --  bytes, by its bit.
   --
   --  @param Format A grid format.
   --  @return Where its grid is.
   function Grid_Address (Format : Model_Runner.GGUF.Tensor_Type) return System.Address;

   --  @return Where the seven-bit sign indices' +1/-1 words are.
   function Sign_Ones_Address return System.Address;

   --  @return Where a sign byte's +1/-1 words are.
   function Byte_Sign_Ones_Address return System.Address;

   --  @return Where IQ1's two offset words are, +1 then -1.
   function Offset_Words_Address return System.Address;

   --  @return Where a byte's eight bits are, a byte each, 0 or 1: IQ3_S's
   --    ninth index bits, widened beside its eight index bytes.
   function Bit_Bytes_Address return System.Address;

   --  A super-block's factors, two a sub-block of thirty-two: the first
   --  sixteen elements' and the last sixteen's, each the sub-block's odd
   --  scale as the format states it (2s + 1), whole -- the block's half and
   --  the format's power of two not in them: the half's bits are given
   --  apart, for an instruction to widen. IQ1_M's alone are read; the
   --  others are worked out where they are used.
   type Factor_Block is array (0 .. 15) of Model_Runner.Numerics.Real
     with Alignment => 32;

   --  @param Format A grid format.
   --  @param Data Buffer holding the block.
   --  @param Offset Byte position of the block, from Data'First.
   --  @param Factors Receives them.
   --  @param Half_Bits Receives the block's half, as its bits.
   procedure Factors_Of
     (Format    : Model_Runner.GGUF.Tensor_Type;
      Data      : Model_Runner.Bytes.Byte_Array;
      Offset    : Model_Runner.Bytes.Byte_Count;
      Factors   : out Factor_Block;
      Half_Bits : out Interfaces.Unsigned_16);

end Model_Runner.Quantization.Grid_Integers;
