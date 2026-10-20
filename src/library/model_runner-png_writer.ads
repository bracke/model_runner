with Model_Runner.Bytes;
with Model_Runner.Errors;

--  A picture written as PNG: eight bits a channel, red, green and blue with
--  alpha or without, every row unfiltered and the whole deflated by the
--  zlib crate. What the image command writes and any viewer reads.
--
--  Task safety: pure; Encode allocates its result.
package Model_Runner.PNG_Writer is

   subtype Channel_Count is Positive range 3 .. 4;

   --  The most pixels a picture written may hold: 4096 on a side.
   Max_Pixels : constant := 4096 * 4096;

   --  Encode a picture.
   --
   --  @param Width pixels a row
   --  @param Height rows
   --  @param Channels three for red, green and blue, four with alpha
   --  @param Pixels rows top first, each pixel's channels in that order
   --  @param Result the file's bytes, null on failure; the caller frees them
   --  @param Status success, Tensor_Shape_Mismatch where Pixels is not
   --    Width * Height * Channels long or the picture is past Max_Pixels,
   --    or Memory_Allocation_Failed where the compression would not fit
   procedure Encode
     (Width    : Positive;
      Height   : Positive;
      Channels : Channel_Count;
      Pixels   : Model_Runner.Bytes.Byte_Array;
      Result   : out Model_Runner.Bytes.Byte_Array_Access;
      Status   : out Model_Runner.Errors.Error_Info);

end Model_Runner.PNG_Writer;
