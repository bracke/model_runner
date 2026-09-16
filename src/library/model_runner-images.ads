--  Pictures, as a model that reads one wants them: rows of pixels, three
--  bytes apiece, at the size the encoder was trained on.
--
--  Three file formats are read. A PNG is inflated by the pure-Ada zlib
--  this build already carries and unfiltered here, in every colour type
--  and bit depth the format has, interlaced or not; a JPEG is decoded by
--  jpeglib, the native Ada codec, baseline and progressive alike; and a
--  PPM -- the binary P6 and its grey P5 -- is read as it stands, which is
--  what a test writes when it wants a picture whose pixels it knows. A
--  picture's transparency is dropped: the encoders here were trained on
--  opaque pictures, and what a transparent pixel is over is nobody's to
--  decide but the caller's, who can flatten it first.
--
--  A picture is resampled to the encoder's size the way the reference
--  pipeline resamples it -- a triangle filter whose support widens with
--  the shrink, so that every source pixel counts in a picture made
--  smaller, rather than the four nearest -- because a model's first layer
--  is a linear map of the pixels and a different resampling is a different
--  input.
--
--  Task safety: pure bytes in, pixels out; no state of its own.

with Model_Runner.Bytes;
with Model_Runner.Errors;

package Model_Runner.Images is

   --  Rows of pixels, top row first, each pixel red, green and blue in
   --  that order: Pixels (3 * (Y * Width + X) + 0 .. 2), indexed from 0.
   type Raster is record
      Width  : Natural := 0;
      Height : Natural := 0;
      Pixels : Model_Runner.Bytes.Byte_Array_Access := null;
   end record;

   --  Most pixels a picture may hold. Sixty-four million is a picture 8192
   --  on a side, three times the bytes of the largest sensible photograph
   --  and a bound on what an inflate is allowed to produce.
   Max_Pixels : constant := 2 ** 26;

   --  Most bytes a picture file may hold: 256 MB, which no picture worth
   --  handing an encoder the size of a postcard comes near.
   Max_File_Bytes : constant := 2 ** 28;

   --  Read a picture from a file.
   --
   --  @param Path The file.
   --  @param Result The pixels, or an empty raster on failure.
   --  @param Status Success, IO_Open_Failed, IO_File_Too_Large or
   --    IO_Image_Unreadable, the last naming what the decoder objected to.
   procedure Load
     (Path   : String;
      Result : out Raster;
      Status : out Model_Runner.Errors.Error_Info);

   --  Read a picture from its bytes, which is what Load does once it has
   --  them; here for a caller that has them already.
   --
   --  @param Data The file's bytes.
   --  @param Name What to call the picture in a diagnostic.
   --  @param Result The pixels, or an empty raster on failure.
   --  @param Status Success or IO_Image_Unreadable.
   procedure Decode
     (Data   : Model_Runner.Bytes.Byte_Array;
      Name   : String;
      Result : out Raster;
      Status : out Model_Runner.Errors.Error_Info);

   --  Resample a picture to a size, the way the reference pipeline does:
   --  separably, with a triangle filter whose support is the shrink
   --  factor where the picture is made smaller and one pixel where it is
   --  made larger.
   --
   --  @param Source The picture.
   --  @param Width Wanted width.
   --  @param Height Wanted height.
   --  @param Result The resampled picture, or an empty raster when
   --    Source is empty or the allocation failed.
   procedure Resample
     (Source : Raster;
      Width  : Positive;
      Height : Positive;
      Result : out Raster);

   --  Release a raster's pixels. Idempotent.
   --
   --  @param Item Raster to release.
   procedure Free (Item : in out Raster);

end Model_Runner.Images;
