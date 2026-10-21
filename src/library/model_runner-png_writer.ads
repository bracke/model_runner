with Model_Runner.Bytes;
with Model_Runner.Errors;

--  A picture written as PNG: eight bits a channel, red, green and blue with
--  alpha or without, every row through the Sub filter and the whole deflated
--  by the zlib crate with its fixed codes. What the image command writes and
--  any viewer reads.
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

   --  Where the picture Index of Count goes, Path given for them all: Path
   --  itself for one picture; for more, Path with -Index set before its
   --  extension -- apple.png, apple-1.png -- or after it where the name
   --  has none. A dot in a directory's name is not an extension's.
   --
   --  @param Path The name given.
   --  @param Index Which picture, from one.
   --  @param Count How many.
   --  @return The picture's name.
   function Numbered (Path : String; Index : Positive; Count : Positive) return String;

end Model_Runner.PNG_Writer;
