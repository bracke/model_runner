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

   --  A rectangle of a picture, copied out.
   --
   --  @param Source The picture.
   --  @param Left Column the crop starts at.
   --  @param Top Row the crop starts at.
   --  @param Width Columns wanted; cut at the picture's edge.
   --  @param Height Rows wanted; cut at the picture's edge.
   --  @param Result The crop, or an empty raster when the rectangle lies
   --    outside the picture or the allocation failed.
   procedure Crop
     (Source : Raster;
      Left   : Natural;
      Top    : Natural;
      Width  : Positive;
      Height : Positive;
      Result : out Raster);

   --  How a picture is cut into crops for pan-and-scan: a grid of tiles
   --  across the longer side, the whole picture being shown as well. The
   --  reference pipeline's rule -- a picture whose longer side is at
   --  least Min_Ratio times its shorter is cut into as many tiles along
   --  it as the ratio rounds to, at least two, at most Max_Crops, none
   --  narrower than Min_Crop pixels; a picture nearer square, or too
   --  small to cut, is not cut at all.
   type Tiling is record
      Across : Natural := 0;
      Down   : Natural := 0;
   end record;

   --  No crops at all.
   Uncut : constant Tiling := (0, 0);

   --  The crops a picture of a size gets.
   --
   --  @param Width The picture's width.
   --  @param Height The picture's height.
   --  @param Min_Crop Narrowest a crop may be, in pixels.
   --  @param Max_Crops Most crops along the longer side.
   --  @param Min_Ratio The longer side over the shorter, below which
   --    the picture is left whole.
   --  @return The grid, or Uncut.
   function Pan_And_Scan
     (Width     : Positive;
      Height    : Positive;
      Min_Crop  : Positive := 256;
      Max_Crops : Positive := 4;
      Min_Ratio : Float := 1.2) return Tiling;

   --  The rectangle one crop of a grid covers: the picture's side divided
   --  into the grid's count, rounded up, the last crop cut at the edge.
   --
   --  @param Width The picture's width.
   --  @param Height The picture's height.
   --  @param Grid The tiling.
   --  @param Column Which crop across, from zero.
   --  @param Row Which crop down, from zero.
   --  @param Left Where the crop starts.
   --  @param Top Where the crop starts.
   --  @param Crop_Width How wide it is.
   --  @param Crop_Height How tall it is.
   procedure Crop_Bounds
     (Width       : Positive;
      Height      : Positive;
      Grid        : Tiling;
      Column      : Natural;
      Row         : Natural;
      Left        : out Natural;
      Top         : out Natural;
      Crop_Width  : out Positive;
      Crop_Height : out Positive)
   with Pre => Column < Grid.Across and then Row < Grid.Down;

   --  Release a raster's pixels. Idempotent.
   --
   --  @param Item Raster to release.
   procedure Free (Item : in out Raster);

end Model_Runner.Images;
