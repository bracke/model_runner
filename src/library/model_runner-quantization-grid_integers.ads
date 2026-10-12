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

   --  And its odd scales: element E's weight is its byte times Odds (E / 2)
   --  times the block's unit, the pair of elements a sixteen-bit multiply
   --  of a byte product covers.
   type Odd_Block is array (0 .. 127) of Interfaces.Integer_16
     with Alignment => 32;

   --  Decode one super-block.
   --
   --  @param Format A grid format.
   --  @param Data Buffer holding the block.
   --  @param Offset Byte position of the block, from Data'First; the whole
   --    block lies inside Data.
   --  @param Words Receives the weights as bytes.
   --  @param Odds Receives the odd scale of each two.
   --  @param Unit Receives the block's unit, its scale and the format's
   --    constant together.
   procedure Decode
     (Format : Model_Runner.GGUF.Tensor_Type;
      Data   : Model_Runner.Bytes.Byte_Array;
      Offset : Model_Runner.Bytes.Byte_Count;
      Words  : out Word_Block;
      Odds   : out Odd_Block;
      Unit   : out Model_Runner.Numerics.Real);

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

   --  @return Where eight shuffles are, thirty-two bytes each: sub-block
   --    S's, which spread the sixteen-bit scale pair 2S, 2S + 1 of each
   --    half of a register over that half -- the two-bit grids' sixteen
   --    scales made once a block, a sub-block's two picked out by one
   --    instruction, as llama.cpp picks IQ2_S's.
   function Scale_Shuffle_Address return System.Address;

   --  @return Where IQ1_M's scale constants are: four quadword shifts (0, 6,
   --    3, 9) that bring a block's sixteen three-bit scales to the bottom of
   --    the sixteen-bit words, then eight shuffles picking sub-block S's two
   --    -- its first half's from the low half of a register, its second's
   --    from the high, as llama.cpp arranges them.
   function IQ1M_Scales_Address return System.Address;

   --  @return Where sixteen vectors of thirty-two bytes are, +1 or -1 by
   --    the four bits of their index, eight bytes a bit: IQ1_M's offsets'
   --    signs for a sub-block, one load where they were built.
   function Offset_Signs_Address return System.Address;

   --  @return Where two shuffle constants are, thirty-two bytes each: which
   --    of four sign bytes each of thirty-two elements reads, and which of
   --    its bits -- a sub-block's signs made a mask in the registers, as
   --    llama.cpp makes IQ3_S's.
   function Sign_Shuffle_Address return System.Address;

end Model_Runner.Quantization.Grid_Integers;
