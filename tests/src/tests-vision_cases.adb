with Ada.Directories;
with Ada.Numerics;
with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;
with AUnit.Assertions;
with Interfaces;

with Fixtures;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.CLI.Pictures;
with Model_Runner.Platform.Video;
with Model_Runner.Video;
with Model_Runner.Errors;
with Model_Runner.GGUF;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Generation;
with Model_Runner.Images;
with Model_Runner.Kernels;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Sampling;
with Model_Runner.Stops;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Model_Runner.Tokenizer;
with Model_Runner.Vision;
with Tiny_Model;

package body Tests.Vision_Cases is

   use AUnit.Assertions;

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package G renames Model_Runner.GGUF;
   package Gen renames Model_Runner.Generation;
   package Images renames Model_Runner.Images;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;
   package Vocab renames Model_Runner.Tokenizer;
   package Vision renames Model_Runner.Vision;

   use type B.Byte_Count;
   use type B.Byte_Array;
   use type B.Byte_Array_Access;
   use type E.Error_Code;
   use type N.Element_Count;
   use type N.Real;
   use type N.Wide_Real;
   use type T.Real_Array_Access;
   use type Vocab.Token_Id;

   procedure Free is new Ada.Unchecked_Deallocation
     (Gen.Crop_Counts, Gen.Crop_Counts_Access);

   package Wide_Math is
     new Ada.Numerics.Generic_Elementary_Functions (N.Wide_Real);

   --  A byte array from a string, indexed from one.
   function Bytes_Of (Text : String) return B.Byte_Array is
      Result : B.Byte_Array (1 .. B.Byte_Count (Text'Length));
   begin
      for Index in Text'Range loop
         Result (B.Byte_Count (Index - Text'First + 1)) :=
           Character'Pos (Text (Index));
      end loop;
      return Result;
   end Bytes_Of;

   --  A pixel's channel of a raster.
   function Pixel
     (Item : Images.Raster; X, Y : Natural; Channel : Natural) return Natural
   is (Natural (Item.Pixels
                  (3 * (B.Byte_Count (Y) * B.Byte_Count (Item.Width)
                        + B.Byte_Count (X)) + B.Byte_Count (Channel))));

   --  A PNG written with stored deflate blocks, which needs no
   --  compressor: the signature, a header, the palette where there is
   --  one, the scanlines -- a filter byte and the samples -- in one
   --  IDAT, and the end.
   function Stored_PNG
     (Width, Height : Natural;
      Depth, Colour : Natural;
      Scanlines     : B.Byte_Array;
      Palette       : B.Byte_Array := [1 .. 0 => 0];
      Interlaced    : Boolean := False) return B.Byte_Array
   is
      use Interfaces;

      function Big (Value : Unsigned_32) return B.Byte_Array
      is ([B.Byte (Shift_Right (Value, 24) and 16#FF#),
           B.Byte (Shift_Right (Value, 16) and 16#FF#),
           B.Byte (Shift_Right (Value, 8) and 16#FF#),
           B.Byte (Value and 16#FF#)]);

      function Chunk (Kind : String; Data : B.Byte_Array) return B.Byte_Array
      is (Big (Unsigned_32 (Data'Length)) & Bytes_Of (Kind) & Data
          & Big (0));

      --  The zlib stream: the header, then stored blocks of at most 65535
      --  bytes each, then the Adler-32 checksum, which the reader here
      --  does not verify but the format asks for.
      function Deflated return B.Byte_Array is
         Result : B.Byte_Array (1 .. Scanlines'Length + 16
                                + 5 * (Scanlines'Length / 65535 + 1));
         Last   : B.Byte_Count := 0;
         From   : B.Byte_Count := Scanlines'First;
         A      : Unsigned_32 := 1;
         Bb     : Unsigned_32 := 0;

         procedure Put (Value : B.Byte) is
         begin
            Last := Last + 1;
            Result (Last) := Value;
         end Put;
      begin
         Put (16#78#);
         Put (16#01#);
         loop
            declare
               Take  : constant B.Byte_Count :=
                 B.Byte_Count'Min (65535, Scanlines'Last - From + 1);
               Final : constant Boolean := From + Take > Scanlines'Last;
               Len   : constant Unsigned_16 := Unsigned_16 (Take);
            begin
               Put (if Final then 1 else 0);
               Put (B.Byte (Len and 16#FF#));
               Put (B.Byte (Shift_Right (Len, 8)));
               Put (B.Byte ((not Len) and 16#FF#));
               Put (B.Byte (Shift_Right (not Len, 8)));
               for Index in From .. From + Take - 1 loop
                  Put (Scanlines (Index));
                  A := (A + Unsigned_32 (Scanlines (Index))) mod 65521;
                  Bb := (Bb + A) mod 65521;
               end loop;
               From := From + Take;
               exit when Final;
            end;
         end loop;
         declare
            Adler : constant B.Byte_Array := Big (Shift_Left (Bb, 16) or A);
         begin
            for Value of Adler loop
               Put (Value);
            end loop;
         end;
         return Result (1 .. Last);
      end Deflated;

      Header : constant B.Byte_Array :=
        Big (Unsigned_32 (Width)) & Big (Unsigned_32 (Height))
        & [B.Byte (Depth), B.Byte (Colour), 0, 0,
           (if Interlaced then 1 else 0)];
   begin
      return
        [16#89#, 16#50#, 16#4E#, 16#47#, 16#0D#, 16#0A#, 16#1A#, 16#0A#]
        & Chunk ("IHDR", Header)
        & (if Palette'Length > 0 then Chunk ("PLTE", Palette)
           else [1 .. 0 => 0])
        & Chunk ("IDAT", Deflated)
        & Chunk ("IEND", [1 .. 0 => 0]);
   end Stored_PNG;

   ------------------------------------
   -- Pictures_Decode_And_Resample --
   ------------------------------------

   --  A PPM's pixels are its bytes; a PNG's are its filtered scanlines
   --  undone, in every colour type, at every depth, interlaced or not; a
   --  JPEG's come from jpeglib; and what is none of those is refused by
   --  name. Resampling averages what it shrinks and keeps what it keeps.
   procedure Pictures_Decode_And_Resample
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Picture : Images.Raster;
      Status  : E.Error_Info;

      procedure Expect_Refusal (Data : B.Byte_Array; Detail : String) is
         Found : Boolean;
         Held  : E.Parameter;
      begin
         Images.Decode (Data, "test", Picture, Status);
         Assert (Status.Code = E.IO_Image_Unreadable,
                 Detail & " was not refused: "
                 & E.Error_Code'Image (Status.Code));
         E.Find_Parameter (Status, "detail", Found, Held);
         Assert (Found
                 and then Model_Runner.Text.To_String (Held.Text_Value)
                          = Detail,
                 "the refusal of " & Detail & " named "
                 & (if Found then Model_Runner.Text.To_String (Held.Text_Value)
                    else "nothing"));
         Assert (Picture.Pixels = null, "a refused picture kept pixels");
      end Expect_Refusal;
   begin
      --  PPM, colour and grey, with a comment in the header.
      Images.Decode
        (Bytes_Of ("P6" & ASCII.LF & "# two by one" & ASCII.LF & "2 1"
                   & ASCII.LF & "255" & ASCII.LF)
         & [255, 0, 0, 0, 0, 255],
         "test", Picture, Status);
      Assert (E.Is_Ok (Status), "the PPM was refused");
      Assert (Picture.Width = 2 and then Picture.Height = 1,
              "the PPM's size was misread");
      Assert (Pixel (Picture, 0, 0, 0) = 255 and then Pixel (Picture, 0, 0, 2) = 0
              and then Pixel (Picture, 1, 0, 2) = 255,
              "the PPM's pixels were misread");
      Images.Free (Picture);

      Images.Decode
        (Bytes_Of ("P5 1 2 255 ") & [7, 200], "test", Picture, Status);
      Assert (E.Is_Ok (Status) and then Picture.Height = 2
              and then Pixel (Picture, 0, 1, 0) = 200
              and then Pixel (Picture, 0, 1, 1) = 200,
              "a grey PPM did not spread its grey over the channels");
      Images.Free (Picture);

      --  PNG, eight-bit colour, every filter in turn: none, sub, up,
      --  average and Paeth, one a scanline, over a two-pixel-wide picture
      --  whose pixels are (10,20,30) and (40,50,60) on every row.
      declare
         Lines : constant B.Byte_Array :=
           [0, 10, 20, 30, 40, 50, 60,          --  none
            1, 10, 20, 30, 30, 30, 30,          --  sub: right = left + 30
            2, 0, 0, 0, 0, 0, 0,                --  up: same as the row above
            3, 5, 10, 15, 15, 15, 15,           --  average: (left+up)/2
            4, 0, 0, 0, 0, 0, 0];               --  Paeth: predicts up
      begin
         Images.Decode (Stored_PNG (2, 5, 8, 2, Lines), "test", Picture, Status);
         Assert (E.Is_Ok (Status), "the eight-bit PNG was refused: "
                 & E.Error_Code'Image (Status.Code));
         for Y in 0 .. 4 loop
            Assert (Pixel (Picture, 0, Y, 0) = 10
                    and then Pixel (Picture, 0, Y, 2) = 30
                    and then Pixel (Picture, 1, Y, 0) = 40
                    and then Pixel (Picture, 1, Y, 1) = 50
                    and then Pixel (Picture, 1, Y, 2) = 60,
                    "filter" & Natural'Image (Y) & " was undone wrongly");
         end loop;
         Images.Free (Picture);
      end;

      --  Sixteen-bit RGBA keeps the high byte and drops the alpha; a
      --  two-bit palette reads its indices out of the packed byte; and
      --  one-bit grey spreads to black and white.
      Images.Decode
        (Stored_PNG (1, 1, 16, 6,
                     [0, 16#12#, 16#34#, 16#56#, 16#78#, 16#9A#, 16#BC#,
                      16#FF#, 16#00#]),
         "test", Picture, Status);
      Assert (E.Is_Ok (Status) and then Pixel (Picture, 0, 0, 0) = 16#12#
              and then Pixel (Picture, 0, 0, 1) = 16#56#
              and then Pixel (Picture, 0, 0, 2) = 16#9A#,
              "sixteen-bit samples did not keep their high byte");
      Images.Free (Picture);

      Images.Decode
        (Stored_PNG (3, 1, 2, 3, [0, 2#01_10_11_00#],
                     Palette => [0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255]),
         "test", Picture, Status);
      Assert (E.Is_Ok (Status) and then Pixel (Picture, 0, 0, 0) = 255
              and then Pixel (Picture, 1, 0, 1) = 255
              and then Pixel (Picture, 2, 0, 2) = 255,
              "a two-bit palette was read wrongly");
      Images.Free (Picture);

      Images.Decode
        (Stored_PNG (4, 1, 1, 0, [0, 2#1010_0000#]), "test", Picture, Status);
      Assert (E.Is_Ok (Status) and then Pixel (Picture, 0, 0, 0) = 255
              and then Pixel (Picture, 1, 0, 0) = 0
              and then Pixel (Picture, 2, 0, 0) = 255,
              "one-bit grey did not spread to white and black");
      Images.Free (Picture);

      --  Adam7: a two-by-two grey picture is three passes -- the first
      --  holds (0,0), the sixth (1,0) and the seventh the bottom row.
      Images.Decode
        (Stored_PNG (2, 2, 8, 0, [0, 1, 0, 2, 0, 3, 4], Interlaced => True),
         "test", Picture, Status);
      Assert (E.Is_Ok (Status) and then Pixel (Picture, 0, 0, 0) = 1
              and then Pixel (Picture, 1, 0, 0) = 2
              and then Pixel (Picture, 0, 1, 0) = 3
              and then Pixel (Picture, 1, 1, 0) = 4,
              "the interlaced PNG's passes were put back wrongly");
      Images.Free (Picture);

      --  JPEG, through jpeglib: two of its fixtures, one colour and one
      --  grey, both a flat 128.
      Images.Load ("fixtures/picture-rgb-8x8.jpg", Picture, Status);
      Assert (E.Is_Ok (Status), "the colour JPEG was refused: "
              & E.Error_Code'Image (Status.Code));
      Assert (Picture.Width = 8 and then Picture.Height = 8
              and then Pixel (Picture, 3, 3, 1) in 126 .. 130,
              "the colour JPEG decoded wrongly");
      Images.Free (Picture);
      Images.Load ("fixtures/picture-gray-16x8.jpg", Picture, Status);
      Assert (E.Is_Ok (Status) and then Picture.Width = 16
              and then Pixel (Picture, 15, 7, 2) in 126 .. 130,
              "the grey JPEG decoded wrongly");
      Images.Free (Picture);

      --  Refusals, each naming what was wrong.
      Expect_Refusal (Bytes_Of ("GIF89a......"), "format");
      Expect_Refusal (Bytes_Of ("P6 0 1 255 "), "ppm header");
      Expect_Refusal (Bytes_Of ("P6 2 2 255 ") & [1, 2, 3], "ppm pixels");
      declare
         Whole : constant B.Byte_Array :=
           Stored_PNG (2, 1, 8, 2, [0, 1, 2, 3, 4, 5, 6]);
      begin
         Expect_Refusal (Whole (Whole'First .. Whole'First + 44), "png chunk");
         Expect_Refusal (Whole (Whole'First .. Whole'First + 39), "png chunks");
      end;
      Expect_Refusal (Stored_PNG (2, 1, 8, 7, [0, 1, 2, 3, 4, 5, 6]),
                      "png colour type");
      Expect_Refusal (Stored_PNG (2, 1, 8, 2, [0, 1, 2]), "png scanlines");
      Expect_Refusal (Stored_PNG (2, 1, 8, 2, [9, 1, 2, 3, 4, 5, 6]),
                      "png scanlines");

      Images.Load ("fixtures/no-such-picture.png", Picture, Status);
      Assert (Status.Code = E.IO_Open_Failed,
              "a missing picture was not reported as unopenable");

      --  Resampling: a shrink averages what it drops, and a stretch
      --  interpolates. A two-by-two of 0 and 200 to one pixel is 100;
      --  a four-wide row of 0,0,200,200 to two pixels is 29 and 171, the
      --  triangle reaching a pixel into the other half, as the reference
      --  pipeline's does.
      declare
         Source, Result : Images.Raster;
      begin
         Images.Decode
           (Bytes_Of ("P5 2 2 255 ") & [0, 200, 200, 0], "test", Source, Status);
         Images.Resample (Source, 1, 1, Result);
         Assert (Result.Pixels /= null and then Pixel (Result, 0, 0, 0) = 100,
                 "a shrink to one pixel is not the average");
         Images.Free (Result);
         Images.Resample (Source, 4, 4, Result);
         Assert (Result.Width = 4 and then Pixel (Result, 0, 0, 0) = 0
                 and then Pixel (Result, 3, 0, 0) = 200
                 and then Pixel (Result, 1, 0, 0) in 40 .. 60
                 and then Pixel (Result, 2, 0, 0) in 140 .. 160,
                 "a stretch did not interpolate between the two pixels");
         Images.Free (Result);
         Images.Free (Source);

         Images.Decode
           (Bytes_Of ("P5 4 1 255 ") & [0, 0, 200, 200], "test", Source, Status);
         Images.Resample (Source, 2, 1, Result);
         Assert (Pixel (Result, 0, 0, 0) in 27 .. 31
                 and then Pixel (Result, 1, 0, 0) in 169 .. 173,
                 "a halving did not weigh the halves as the triangle does:"
                 & Natural'Image (Pixel (Result, 0, 0, 0))
                 & Natural'Image (Pixel (Result, 1, 0, 0)));
         Images.Free (Result);
         Images.Free (Source);
      end;

      --  Pan-and-scan, by the reference's rule: a picture 1.2 times as
      --  long as it is wide is cut, one nearer square is not; the count
      --  is the ratio rounded half up, at least two, at most four, and
      --  held to crops of 256 pixels -- a picture too narrow for two of
      --  them is left whole however long it is.
      declare
         use type Images.Tiling;
         function Plan (Width, Height : Positive) return Images.Tiling
         is (Images.Pan_And_Scan (Width, Height));
      begin
         Assert (Plan (896, 896) = Images.Uncut,
                 "a square picture was cut");
         Assert (Plan (1000, 900) = Images.Uncut,
                 "a picture nearer square than 1.2 was cut");
         Assert (Plan (1920, 1080) = (Across => 2, Down => 1),
                 "a 16:9 picture was not cut in two across");
         Assert (Plan (1080, 1920) = (Across => 1, Down => 2),
                 "a 9:16 picture was not cut in two down");
         Assert (Plan (1000, 400) = (Across => 3, Down => 1),
                 "a picture two and a half times as wide was not cut in three");
         Assert (Plan (4000, 500) = (Across => 4, Down => 1),
                 "a picture eight times as wide was cut into more than four");
         Assert (Plan (600, 300) = (Across => 2, Down => 1),
                 "a picture twice as wide, 300 tall, was not cut in two");
         Assert (Plan (600, 200) = Images.Uncut,
                 "a picture 200 tall was cut into crops shorter than 256");
         Assert (Plan (300, 100) = Images.Uncut,
                 "a picture 300 wide was cut into crops narrower than 256");
      end;

      --  A crop's bounds and its pixels: the side divided into the
      --  count, rounded up, the last crop what is left; and the pixels
      --  are the source's at that offset.
      declare
         Source, Piece : Images.Raster;
         Left, Top : Natural;
         Wide, Tall : Positive;
         Data : B.Byte_Array (0 .. 3 * 5 * 2 - 1);
      begin
         Images.Crop_Bounds
           (1000, 400, (Across => 3, Down => 1), 2, 0, Left, Top, Wide, Tall);
         Assert (Left = 668 and then Top = 0 and then Wide = 332
                 and then Tall = 400,
                 "the last of three crops of 1000 is not 332 from 668");
         Images.Crop_Bounds
           (1000, 400, (Across => 3, Down => 1), 0, 0, Left, Top, Wide, Tall);
         Assert (Left = 0 and then Wide = 334,
                 "the first of three crops of 1000 is not 334 wide");

         --  Five pixels by two, each byte its own index.
         for Index in Data'Range loop
            Data (Index) := B.Byte (Index);
         end loop;
         Images.Decode
           (Bytes_Of ("P6 5 2 255 ") & Data, "test", Source, Status);
         Assert (E.Is_Ok (Status), "the five-by-two PPM did not decode");
         Images.Crop (Source, 3, 1, 4, 4, Piece);
         Assert (Piece.Width = 2 and then Piece.Height = 1,
                 "a crop past the edge was not cut to what is there");
         Assert (Pixel (Piece, 0, 0, 0) = 3 * (5 + 3)
                 and then Pixel (Piece, 1, 0, 2) = 3 * (5 + 4) + 2,
                 "the crop's pixels are not the source's at its offset");
         Images.Free (Piece);
         Images.Crop (Source, 5, 0, 1, 1, Piece);
         Assert (Piece.Pixels = null,
                 "a crop outside the picture was not empty");
         Images.Free (Source);
      end;
   end Pictures_Decode_And_Resample;

   -------------------------------------------
   -- The_Projector_Encodes_As_The_Reference --
   -------------------------------------------

   --  A projector's shape, written small.
   Size_P    : constant := 56;    --  four patches a side
   Patch_P   : constant := 14;
   Side_P    : constant := Size_P / Patch_P;
   Patches_P : constant := Side_P * Side_P;
   Width_P   : constant := 8;
   Heads_P   : constant := 2;
   Head_P    : constant := Width_P / Heads_P;
   Feed_P    : constant := 16;
   Blocks_P  : constant := 2;
   Text_P    : constant := 12;
   Elements_P : constant := 3 * Patch_P * Patch_P;

   --  Deterministic weights: a linear congruential walk, scaled small.
   Seed : Interfaces.Unsigned_32 := 12345;

   function Next return N.Real is
      use Interfaces;
   begin
      Seed := Seed * 1_664_525 + 1_013_904_223;
      return N.Real (Shift_Right (Seed, 8) mod 2000) / 1000.0 - 1.0;
   end Next;

   function Random_Row (Length : N.Element_Count; Scale : N.Real)
     return N.Real_Array
   is
      Result : N.Real_Array (0 .. Length - 1);
   begin
      for Value of Result loop
         Value := Next * Scale;
      end loop;
      return Result;
   end Random_Row;

   --  Every weight of the small projector, kept so that the reference
   --  can read the same numbers the file holds.
   type Block_Weights is record
      Ln1_W, Ln1_B, Ln2_W, Ln2_B : N.Real_Array (0 .. Width_P - 1);
      Q, K, V, O : N.Real_Array (0 .. Width_P * Width_P - 1);
      Q_B, K_B, V_B, O_B : N.Real_Array (0 .. Width_P - 1);
      Up   : N.Real_Array (0 .. Feed_P * Width_P - 1);   --  Feed rows of Width
      Up_B : N.Real_Array (0 .. Feed_P - 1);
      Down : N.Real_Array (0 .. Width_P * Feed_P - 1);   --  Width rows of Feed
      Down_B : N.Real_Array (0 .. Width_P - 1);
   end record;

   type Block_Weights_List is array (0 .. Blocks_P - 1) of Block_Weights;

   type Projector_Weights is record
      Patch  : N.Real_Array (0 .. Width_P * Elements_P - 1);
      Patch_B : N.Real_Array (0 .. Width_P - 1);
      Pos    : N.Real_Array (0 .. Patches_P * Width_P - 1);
      Blocks : Block_Weights_List;
      Post_W, Post_B, Soft : N.Real_Array (0 .. Width_P - 1);
      Proj   : N.Real_Array (0 .. Width_P * Text_P - 1);  --  Width rows of Text
   end record;

   type Projector_Weights_Access is access Projector_Weights;

   function Fresh_Weights return Projector_Weights_Access is
      W : constant Projector_Weights_Access := new Projector_Weights;
   begin
      Seed := 12345;
      W.Patch := Random_Row (Width_P * Elements_P, 0.05);
      W.Patch_B := Random_Row (Width_P, 0.1);
      W.Pos := Random_Row (Patches_P * Width_P, 0.3);
      for Index in W.Blocks'Range loop
         W.Blocks (Index).Ln1_W := Random_Row (Width_P, 0.3);
         for Value of W.Blocks (Index).Ln1_W loop
            Value := Value + 1.0;
         end loop;
         W.Blocks (Index).Ln1_B := Random_Row (Width_P, 0.1);
         W.Blocks (Index).Ln2_W := Random_Row (Width_P, 0.3);
         for Value of W.Blocks (Index).Ln2_W loop
            Value := Value + 1.0;
         end loop;
         W.Blocks (Index).Ln2_B := Random_Row (Width_P, 0.1);
         W.Blocks (Index).Q := Random_Row (Width_P * Width_P, 0.3);
         W.Blocks (Index).K := Random_Row (Width_P * Width_P, 0.3);
         W.Blocks (Index).V := Random_Row (Width_P * Width_P, 0.3);
         W.Blocks (Index).O := Random_Row (Width_P * Width_P, 0.3);
         W.Blocks (Index).Q_B := Random_Row (Width_P, 0.1);
         W.Blocks (Index).K_B := Random_Row (Width_P, 0.1);
         W.Blocks (Index).V_B := Random_Row (Width_P, 0.1);
         W.Blocks (Index).O_B := Random_Row (Width_P, 0.1);
         W.Blocks (Index).Up := Random_Row (Feed_P * Width_P, 0.3);
         W.Blocks (Index).Up_B := Random_Row (Feed_P, 0.1);
         W.Blocks (Index).Down := Random_Row (Width_P * Feed_P, 0.2);
         W.Blocks (Index).Down_B := Random_Row (Width_P, 0.1);
      end loop;
      W.Post_W := Random_Row (Width_P, 0.3);
      for Value of W.Post_W loop
         Value := Value + 1.0;
      end loop;
      W.Post_B := Random_Row (Width_P, 0.1);
      W.Soft := Random_Row (Width_P, 0.3);
      for Value of W.Soft loop
         Value := Value + 1.0;
      end loop;
      W.Proj := Random_Row (Width_P * Text_P, 0.3);
      return W;
   end Fresh_Weights;

   --  Write the projector as a GGUF file, naming the feed-forward halves
   --  as the converter names them -- the one that widens "ffn_down" --
   --  or the other way round, which a later converter may.
   procedure Write_Projector
     (Path : String; W : Projector_Weights; Swapped : Boolean;
      Kind : String := "gemma3")
   is
      Builder : Fixtures.Builder;
      File    : B.Byte_Array_Access;
      use Ada.Streams.Stream_IO;
      Handle  : File_Type;

      procedure Tensor
        (Name : String; Dims : Fixtures.Dimension_List; Values : N.Real_Array) is
      begin
         Fixtures.Add_Tensor
           (Builder, Name, Dims, G.Type_F32, Fixtures.Encode_F32 (Values));
      end Tensor;
   begin
      Fixtures.Reset (Builder);
      Fixtures.Add_String (Builder, "general.architecture", "clip");
      Fixtures.Add_String (Builder, "clip.projector_type", Kind);
      Fixtures.Add_U32 (Builder, "clip.vision.image_size", Size_P);
      Fixtures.Add_U32 (Builder, "clip.vision.patch_size", Patch_P);
      Fixtures.Add_U32 (Builder, "clip.vision.embedding_length", Width_P);
      Fixtures.Add_U32 (Builder, "clip.vision.feed_forward_length", Feed_P);
      Fixtures.Add_U32 (Builder, "clip.vision.projection_dim", Text_P);
      Fixtures.Add_U32 (Builder, "clip.vision.block_count", Blocks_P);
      Fixtures.Add_U32 (Builder, "clip.vision.attention.head_count", Heads_P);
      Fixtures.Add_F32
        (Builder, "clip.vision.attention.layer_norm_epsilon", 1.0e-6);
      Fixtures.Begin_Array
        (Builder, "clip.vision.image_mean", G.Value_Float32, 3);
      for Channel in 1 .. 3 loop
         Fixtures.Float_Element (Builder, 0.5);
      end loop;
      Fixtures.End_Array (Builder);
      Fixtures.Begin_Array
        (Builder, "clip.vision.image_std", G.Value_Float32, 3);
      for Channel in 1 .. 3 loop
         Fixtures.Float_Element (Builder, 0.5);
      end loop;
      Fixtures.End_Array (Builder);

      Tensor ("v.patch_embd.weight", [Patch_P, Patch_P, 3, Width_P], W.Patch);
      Tensor ("v.patch_embd.bias", [Width_P], W.Patch_B);
      Tensor ("v.position_embd.weight", [Width_P, Patches_P], W.Pos);
      for Index in W.Blocks'Range loop
         declare
            Prefix : constant String :=
              "v.blk." & Model_Runner.Text.Image (Long_Long_Integer (Index)) & ".";
            Current : Block_Weights renames W.Blocks (Index);
            Widen_Name  : constant String :=
              (if Swapped then "ffn_up" else "ffn_down");
            Narrow_Name : constant String :=
              (if Swapped then "ffn_down" else "ffn_up");
         begin
            Tensor (Prefix & "ln1.weight", [Width_P], Current.Ln1_W);
            Tensor (Prefix & "ln1.bias", [Width_P], Current.Ln1_B);
            Tensor (Prefix & "ln2.weight", [Width_P], Current.Ln2_W);
            Tensor (Prefix & "ln2.bias", [Width_P], Current.Ln2_B);
            Tensor (Prefix & "attn_q.weight", [Width_P, Width_P], Current.Q);
            Tensor (Prefix & "attn_q.bias", [Width_P], Current.Q_B);
            Tensor (Prefix & "attn_k.weight", [Width_P, Width_P], Current.K);
            Tensor (Prefix & "attn_k.bias", [Width_P], Current.K_B);
            Tensor (Prefix & "attn_v.weight", [Width_P, Width_P], Current.V);
            Tensor (Prefix & "attn_v.bias", [Width_P], Current.V_B);
            Tensor (Prefix & "attn_out.weight", [Width_P, Width_P], Current.O);
            Tensor (Prefix & "attn_out.bias", [Width_P], Current.O_B);
            Tensor (Prefix & Widen_Name & ".weight", [Width_P, Feed_P], Current.Up);
            Tensor (Prefix & Widen_Name & ".bias", [Feed_P], Current.Up_B);
            Tensor (Prefix & Narrow_Name & ".weight", [Feed_P, Width_P],
                    Current.Down);
            Tensor (Prefix & Narrow_Name & ".bias", [Width_P], Current.Down_B);
         end;
      end loop;
      Tensor ("v.post_ln.weight", [Width_P], W.Post_W);
      Tensor ("v.post_ln.bias", [Width_P], W.Post_B);
      Tensor ("mm.soft_emb_norm.weight", [Width_P], W.Soft);
      Tensor ("mm.input_projection.weight", [Text_P, Width_P], W.Proj);

      Fixtures.Build (Builder, File);
      Create (Handle, Out_File, Path);
      declare
         Block : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (File.all'Length))
           with Import, Address => File.all'Address;
      begin
         Write (Handle, Block);
      end;
      Close (Handle);
      B.Free (File);
   end Write_Projector;

   --  The rows the small projector should make of a picture, computed
   --  plainly in binary64: the patches, the blocks, the pooling, the
   --  norm and the projection, each as the model's paper writes it.
   procedure Reference_Rows
     (W : Projector_Weights; Picture : Images.Raster;
      Rows : out N.Wide_Real_Array)
   is
      subtype WR is N.Wide_Real;
      type Matrix is array (0 .. Patches_P - 1, 0 .. Width_P - 1) of WR;
      X, H, Q, K, V, A : Matrix;
      F : array (0 .. Patches_P - 1, 0 .. Feed_P - 1) of WR;
      Pixels : Images.Raster;

      function GELU (Value : WR) return WR
      is (0.5 * Value
          * (1.0 + Wide_Math.Tanh
                     (0.797_884_560_802_865_4
                      * (Value + 0.044_715 * Value * Value * Value))));

      procedure Layer_Norm
        (Source : Matrix; Gain, Bias : N.Real_Array; Target : out Matrix) is
      begin
         for P in 0 .. Patches_P - 1 loop
            declare
               Mean, Variance : WR := 0.0;
            begin
               for D in 0 .. Width_P - 1 loop
                  Mean := Mean + Source (P, D);
               end loop;
               Mean := Mean / WR (Width_P);
               for D in 0 .. Width_P - 1 loop
                  Variance := Variance + (Source (P, D) - Mean) ** 2;
               end loop;
               Variance := Variance / WR (Width_P);
               for D in 0 .. Width_P - 1 loop
                  Target (P, D) :=
                    (Source (P, D) - Mean) / Wide_Math.Sqrt (Variance + 1.0e-6)
                    * WR (Gain (N.Element_Count (D))) + WR (Bias (N.Element_Count (D)));
               end loop;
            end;
         end loop;
      end Layer_Norm;

      --  Target (p, r) := sum over c of Source (p, c) * Weight (r, c) + Bias (r).
      procedure Project
        (Source : Matrix; Weight, Bias : N.Real_Array; Target : out Matrix) is
      begin
         for P in 0 .. Patches_P - 1 loop
            for R in 0 .. Width_P - 1 loop
               declare
                  Sum : WR := WR (Bias (N.Element_Count (R)));
               begin
                  for C in 0 .. Width_P - 1 loop
                     Sum := Sum + Source (P, C)
                       * WR (Weight (N.Element_Count (R * Width_P + C)));
                  end loop;
                  Target (P, R) := Sum;
               end;
            end loop;
         end loop;
      end Project;
   begin
      Images.Resample (Picture, Size_P, Size_P, Pixels);

      --  Patches, embedded and placed.
      for PY in 0 .. Side_P - 1 loop
         for PX in 0 .. Side_P - 1 loop
            declare
               P : constant Natural := PY * Side_P + PX;
            begin
               for R in 0 .. Width_P - 1 loop
                  declare
                     Sum : WR := WR (W.Patch_B (N.Element_Count (R)))
                       + WR (W.Pos (N.Element_Count (P * Width_P + R)));
                  begin
                     for C in 0 .. 2 loop
                        for KY in 0 .. Patch_P - 1 loop
                           for KX in 0 .. Patch_P - 1 loop
                              declare
                                 Value : constant WR :=
                                   (WR (Pixel (Pixels, PX * Patch_P + KX,
                                               PY * Patch_P + KY, C)) / 255.0
                                    - 0.5) / 0.5;
                                 Index : constant Natural :=
                                   C * Patch_P * Patch_P + KY * Patch_P + KX;
                              begin
                                 Sum := Sum + Value
                                   * WR (W.Patch (N.Element_Count
                                                    (R * Elements_P + Index)));
                              end;
                           end loop;
                        end loop;
                     end loop;
                     X (P, R) := Sum;
                  end;
               end loop;
            end;
         end loop;
      end loop;
      Images.Free (Pixels);

      for Index in W.Blocks'Range loop
         declare
            Current : Block_Weights renames W.Blocks (Index);
         begin
            Layer_Norm (X, Current.Ln1_W, Current.Ln1_B, H);
            Project (H, Current.Q, Current.Q_B, Q);
            Project (H, Current.K, Current.K_B, K);
            Project (H, Current.V, Current.V_B, V);
            for Hd in 0 .. Heads_P - 1 loop
               for P in 0 .. Patches_P - 1 loop
                  declare
                     Scores : array (0 .. Patches_P - 1) of WR;
                     Largest, Total : WR;
                  begin
                     for O in 0 .. Patches_P - 1 loop
                        Scores (O) := 0.0;
                        for D in 0 .. Head_P - 1 loop
                           Scores (O) := Scores (O)
                             + Q (P, Hd * Head_P + D) * K (O, Hd * Head_P + D);
                        end loop;
                        Scores (O) := Scores (O) / Wide_Math.Sqrt (WR (Head_P));
                     end loop;
                     Largest := Scores (0);
                     for O in 1 .. Patches_P - 1 loop
                        Largest := WR'Max (Largest, Scores (O));
                     end loop;
                     Total := 0.0;
                     for O in 0 .. Patches_P - 1 loop
                        Scores (O) := Wide_Math.Exp (Scores (O) - Largest);
                        Total := Total + Scores (O);
                     end loop;
                     for D in 0 .. Head_P - 1 loop
                        declare
                           Sum : WR := 0.0;
                        begin
                           for O in 0 .. Patches_P - 1 loop
                              Sum := Sum + Scores (O) / Total * V (O, Hd * Head_P + D);
                           end loop;
                           A (P, Hd * Head_P + D) := Sum;
                        end;
                     end loop;
                  end;
               end loop;
            end loop;
            Project (A, Current.O, Current.O_B, H);
            for P in 0 .. Patches_P - 1 loop
               for D in 0 .. Width_P - 1 loop
                  X (P, D) := X (P, D) + H (P, D);
               end loop;
            end loop;

            Layer_Norm (X, Current.Ln2_W, Current.Ln2_B, H);
            for P in 0 .. Patches_P - 1 loop
               for R in 0 .. Feed_P - 1 loop
                  declare
                     Sum : WR := WR (Current.Up_B (N.Element_Count (R)));
                  begin
                     for C in 0 .. Width_P - 1 loop
                        Sum := Sum + H (P, C)
                          * WR (Current.Up (N.Element_Count (R * Width_P + C)));
                     end loop;
                     F (P, R) := GELU (Sum);
                  end;
               end loop;
               for R in 0 .. Width_P - 1 loop
                  declare
                     Sum : WR := WR (Current.Down_B (N.Element_Count (R)));
                  begin
                     for C in 0 .. Feed_P - 1 loop
                        Sum := Sum + F (P, C)
                          * WR (Current.Down (N.Element_Count (R * Feed_P + C)));
                     end loop;
                     X (P, R) := X (P, R) + Sum;
                  end;
               end loop;
            end loop;
         end;
      end loop;

      Layer_Norm (X, W.Post_W, W.Post_B, H);

      --  Pooled four by four -- the whole grid here -- normalized by the
      --  root mean square under the soft gain, projected.
      declare
         Pooled, Normed : array (0 .. Width_P - 1) of WR;
         Squares : WR := 0.0;
      begin
         for D in 0 .. Width_P - 1 loop
            Pooled (D) := 0.0;
            for P in 0 .. Patches_P - 1 loop
               Pooled (D) := Pooled (D) + H (P, D);
            end loop;
            Pooled (D) := Pooled (D) / WR (Patches_P);
            Squares := Squares + Pooled (D) * Pooled (D);
         end loop;
         for D in 0 .. Width_P - 1 loop
            Normed (D) := Pooled (D)
              / Wide_Math.Sqrt (Squares / WR (Width_P) + 1.0e-6)
              * WR (W.Soft (N.Element_Count (D)));
         end loop;
         for J in 0 .. Text_P - 1 loop
            Rows (N.Element_Count (J)) := 0.0;
            for D in 0 .. Width_P - 1 loop
               Rows (N.Element_Count (J)) := Rows (N.Element_Count (J))
                 + Normed (D) * WR (W.Proj (N.Element_Count (D * Text_P + J)));
            end loop;
         end loop;
      end;
   end Reference_Rows;

   --  A small projector, written to a file and opened, encodes a picture
   --  to the rows a plain binary64 computation of the same network
   --  gives -- with the feed-forward halves named either way round --
   --  and a projector of another kind, or one missing a tensor, is
   --  refused by name.
   procedure The_Projector_Encodes_As_The_Reference
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      W : constant Projector_Weights_Access := Fresh_Weights;
      Picture : Images.Raster;
      Status  : E.Error_Info;
      Wanted  : N.Wide_Real_Array (0 .. Text_P - 1);
      Rows    : T.Real_Array_Access;
      Grid_Rows, Grid_Columns : Natural;
      Eyes    : Vision.Encoder;
   begin
      --  A picture with some structure: a gradient with a bright square.
      declare
         Data : B.Byte_Array (1 .. 3 * 20 * 30);
      begin
         for Y in 0 .. 29 loop
            for X in 0 .. 19 loop
               declare
                  At_Pixel : constant B.Byte_Count :=
                    B.Byte_Count (3 * (Y * 20 + X)) + 1;
               begin
                  Data (At_Pixel) := B.Byte (X * 12);
                  Data (At_Pixel + 1) := B.Byte (Y * 8);
                  Data (At_Pixel + 2) :=
                    (if X in 5 .. 12 and then Y in 8 .. 20 then 240 else 30);
               end;
            end loop;
         end loop;
         Images.Decode (Bytes_Of ("P6 20 30 255 ") & Data, "test", Picture,
                        Status);
         Assert (E.Is_Ok (Status), "the test picture was refused");
      end;

      Reference_Rows (W.all, Picture, Wanted);

      for Swapped in Boolean loop
         Write_Projector ("obj/vision-projector.gguf", W.all, Swapped);
         Vision.Open (Eyes, "obj/vision-projector.gguf", Status);
         Assert (E.Is_Ok (Status), "the small projector did not open: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Vision.Is_Ready (Eyes) and then Vision.Image_Size (Eyes) = Size_P
                 and then Vision.Rows_Per_Picture (Eyes) = 1
                 and then Vision.Row_Width (Eyes) = Text_P
                 and then Vision.Projector (Eyes) = "gemma3",
                 "the small projector's shape was misread");

         Vision.Encode (Eyes, Picture, null, Rows, Grid_Rows, Grid_Columns,
                        Status => Status);
         Assert (E.Is_Ok (Status), "the small projector did not encode: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Rows /= null and then Rows.all'Length = Text_P,
                 "the encoder made the wrong number of rows");
         for J in 0 .. N.Element_Count (Text_P - 1) loop
            Assert (abs (N.Wide_Real (Rows (J)) - Wanted (J))
                    <= 1.0e-4 * (1.0 + abs Wanted (J)),
                    "row element" & N.Element_Count'Image (J) & " is "
                    & N.Real'Image (Rows (J)) & " where the reference has "
                    & N.Wide_Real'Image (Wanted (J))
                    & (if Swapped then " with the halves swapped" else ""));
         end loop;
         T.Free (Rows);
         Vision.Close (Eyes);
      end loop;

      --  Refusals.
      Write_Projector ("obj/vision-projector.gguf", W.all, False, Kind => "llava");
      Vision.Open (Eyes, "obj/vision-projector.gguf", Status);
      Assert (Status.Code = E.Arch_Unsupported_Projector,
              "a projector of another kind was not refused by name");
      Assert (not Vision.Is_Ready (Eyes), "a refused projector reads as ready");

      Tiny_Model.Write_Suite_Fixture;
      Vision.Open (Eyes, Tiny_Model.Suite_Fixture, Status);
      Assert (Status.Code = E.Arch_Unsupported_Projector,
              "a text model was taken for a projector");

      Vision.Open (Eyes, "obj/no-such-projector.gguf", Status);
      Assert (E.Is_Error (Status), "a missing projector opened");

      Vision.Encode (Eyes, Picture, null, Rows, Grid_Rows, Grid_Columns,
                     Status => Status);
      Assert (Status.Code = E.Lifecycle_Model_Not_Ready and then Rows = null,
              "a closed encoder encoded");

      Images.Free (Picture);
   end The_Projector_Encodes_As_The_Reference;

   ---------------------------------------
   -- Pictures_Stand_Behind_Their_Markers --
   ---------------------------------------

   --  A picture's rows take the positions the prompt opens for them: the
   --  marker the template wrote, then a soft token a row, then the closer,
   --  and the rows are what the model reads at those positions. A prompt
   --  marking more pictures than were given, or fewer, is refused.
   procedure Pictures_Stand_Behind_Their_Markers
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image, Room => 64);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed : Model_Runner.GGUF.Containers.Container;
         Ready  : L.Model;
         Live   : L.Session;
         Status : E.Error_Info;
         Words  : access constant Vocab.Vocabulary;
         Pictures : Gen.Picture_Set;
         Request  : Gen.Request;
         Stop     : Model_Runner.Stops.Set;
         Outcome  : Gen.Result;
         Width    : constant N.Element_Count := Tiny_Model.Embedding;
         Per      : constant := 3;
      begin
         Model_Runner.GGUF.Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the tiny model did not parse");
         L.Prepare (Ready, Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the tiny model did not prepare");
         Words := L.Vocabulary (Ready);

         --  The marker is the piece "c", which the prompt "cab" holds
         --  once; the soft token and the closer are byte pieces no prompt
         --  of letters ever spells.
         Pictures.Marker := Vocab.Find (Words.all, "c");
         Pictures.Soft := Vocab.Find (Words.all, "<0x64>");
         Pictures.Closer := Vocab.Find (Words.all, "<0x20>");
         Assert (Pictures.Marker /= Vocab.No_Token
                 and then Pictures.Soft /= Vocab.No_Token
                 and then Pictures.Closer /= Vocab.No_Token,
                 "the tiny vocabulary lacks the pieces this test needs");
         Pictures.Per_Picture := Per;
         Pictures.Count := 1;
         T.Allocate (Per * Width, Pictures.Rows);
         Seed := 777;
         for Value of Pictures.Rows.all loop
            Value := Next;
         end loop;

         Model_Runner.Stops.Open (Stop);
         Request.Max_Tokens := 4;
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
         Request.Seed := 1;
         Request.Has_Seed := True;
         Request.Add_Beginning := True;

         L.Open (Live, Ready, 64, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         --  Without pictures, "cab" is the beginning, c and what follows.
         Gen.Generate
           (Ready, Live, "cab", Request, Stop, null, null, null, null, null,
            null, Outcome => Outcome);
         Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                 "the plain run failed: "
                 & E.Error_Code'Image (Outcome.Error.Code));

         --  Where the marker stands: after the beginning and whatever the
         --  tokenizer puts in front of a word.
         declare
            Plain : constant Natural := Outcome.Prompt_Tokens;
            At_Marker : Natural := Natural'Last;
         begin
            for Index in 0 .. Plain - 1 loop
               if L.Committed_Token (Live, Index) = Pictures.Marker then
                  At_Marker := Index;
                  exit;
               end if;
            end loop;
            Assert (At_Marker < Plain, "the plain prompt holds no marker");

            --  With one picture, the marker opens out: three soft tokens
            --  and the closer after it, committed in that order.
            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "cab", Request, Stop, null, null, null, null, null,
               null, Pictures => Pictures, Outcome => Outcome);
            Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                    "the run with a picture failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));
            Assert (Outcome.Prompt_Tokens = Plain + Per + 1,
                    "the prompt with a picture is"
                    & Natural'Image (Outcome.Prompt_Tokens) & " tokens, not"
                    & Natural'Image (Plain + Per + 1));
            Assert (L.Committed_Token (Live, At_Marker) = Pictures.Marker
                    and then L.Committed_Token (Live, At_Marker + 1) = Pictures.Soft
                    and then L.Committed_Token (Live, At_Marker + Per) = Pictures.Soft
                    and then L.Committed_Token (Live, At_Marker + Per + 1)
                             = Pictures.Closer,
                    "the picture's tokens are not where the prompt opened them");
         end;

         --  The rows are read: the same prompt with other rows commits
         --  the same tokens and can answer differently, and a run with
         --  the same rows answers the same.
         declare
            First_Text : constant String := Gen.Generated_Text (Outcome);
         begin
            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "cab", Request, Stop, null, null, null, null,
               null, null, Pictures => Pictures, Outcome => Outcome);
            Assert (Gen.Generated_Text (Outcome) = First_Text,
                    "the same picture twice answered differently");
         end;

         --  The marker's text is rewritten before the prompt is tokenized,
         --  as the reference processor rewrites it: set between the frame's
         --  halves, and with two crops among the words a cut picture is
         --  set among -- here "a" and "b", which the tiny vocabulary
         --  spells -- with a frame a crop. The tokens committed are those
         --  of the rewritten text, each marker opened out, which is what
         --  lets the frame and the template's own text run together into
         --  whatever token the vocabulary has for both.
         declare
            Expected : Vocab.Token_Array (1 .. 128);
            Count    : Natural := 0;
            Read     : Natural;

            --  What the last run, one picture and no frame, committed.
            Framed   : constant Natural := Outcome.Prompt_Tokens;

            --  The tokens of a text with every marker opened out.
            procedure Expect (Text : String) is
               Raw : Vocab.Token_Array (1 .. 128);
            begin
               Vocab.Encode (Words.all, Text, True, False, Raw, Read, Status);
               Assert (E.Is_Ok (Status), "the expected text did not tokenize");
               Count := 0;
               for Index in 1 .. Read loop
                  Count := Count + 1;
                  Expected (Count) := Raw (Index);
                  if Raw (Index) = Pictures.Marker then
                     for Row in 1 .. Per loop
                        Count := Count + 1;
                        Expected (Count) := Pictures.Soft;
                     end loop;
                     Count := Count + 1;
                     Expected (Count) := Pictures.Closer;
                  end if;
               end loop;
            end Expect;

            procedure Check (What : String) is
            begin
               Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                       "the run with " & What & " failed: "
                       & E.Error_Code'Image (Outcome.Error.Code));
               Assert (Outcome.Prompt_Tokens = Count,
                       "the prompt with " & What & " is"
                       & Natural'Image (Outcome.Prompt_Tokens) & " tokens, not"
                       & Natural'Image (Count));
               for Index in 1 .. Count loop
                  Assert (L.Committed_Token (Live, Index - 1) = Expected (Index),
                          "token" & Natural'Image (Index)
                          & " of the prompt with " & What & " is "
                          & Vocab.Token_Id'Image (L.Committed_Token (Live, Index - 1))
                          & ", not " & Vocab.Token_Id'Image (Expected (Index)));
               end loop;
            end Check;
         begin
            --  Framed: "cab" with the marker "c" set between an "a" and
            --  an "a" is "acaab", and the tokens are that text's. (Not a
            --  "b" before it: the tiny vocabulary has a piece "bc", and
            --  the marker would vanish into it -- which is the point of
            --  rewriting the text, and not what this checks.)
            Pictures.Marker_Text := Model_Runner.Text.To_Bounded ("c");
            Pictures.Frame_Before := Model_Runner.Text.To_Bounded ("a");
            Pictures.Frame_After := Model_Runner.Text.To_Bounded ("a");
            Expect ("acaab");
            Assert (Count > Framed, "the frame added nothing");
            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "cab", Request, Stop, null, null, null, null, null,
               null, Pictures => Pictures, Outcome => Outcome);
            Check ("a framed picture");

            --  And with two crops: lead, frame, bridge, frame, gap, frame.
            Pictures.Crops := new Gen.Crop_Counts'(1 => 2);
            Pictures.Crop_Lead := Model_Runner.Text.To_Bounded ("a");
            Pictures.Crop_Bridge := Model_Runner.Text.To_Bounded ("ab");
            Pictures.Crop_Gap := Model_Runner.Text.To_Bounded ("b");
            Expect ("a" & "aca" & "ab" & "aca" & "b" & "aca" & "ab");
            T.Free (Pictures.Rows);
            T.Allocate (3 * Per * Width, Pictures.Rows);
            for Value of Pictures.Rows.all loop
               Value := Next;
            end loop;
            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "cab", Request, Stop, null, null, null, null, null,
               null, Pictures => Pictures, Outcome => Outcome);
            Check ("a cut picture");

            --  A crop's markers are the rewrite's own: a prompt marking
            --  the one picture is right, and one marking none is refused
            --  as before.
            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "ab", Request, Stop, null, null, null, null, null,
               null, Pictures => Pictures, Outcome => Outcome);
            Assert (Gen."=" (Outcome.Reason, Gen.Runtime_Error)
                    and then Outcome.Error.Code = E.Generation_Picture_Count_Mismatch,
                    "a cut picture with no marker was not refused");

            Free (Pictures.Crops);
            Pictures.Marker_Text := Model_Runner.Text.Empty;
            Pictures.Frame_Before := Model_Runner.Text.Empty;
            Pictures.Frame_After := Model_Runner.Text.Empty;
         end;

         --  A large picture's slices: the overview between the marker and
         --  its closer, then each slice between the slice marker and its
         --  own closer, a row-end token between grid rows. Here the marker
         --  is "c", each slice "b", the row-end a line break; a two-slice,
         --  one-column grid, so the rewrite of the marker "c" is
         --  "ac" -- an "a" ahead of the overview -- then "b", a line break,
         --  and "b" (a frame ending in "a" would let the first slice's "b"
         --  merge into "ab"). Each "c" opens to the soft token and the
         --  closer, each
         --  "b" to the soft token and the slice's own closer.
         declare
            Expected : Vocab.Token_Array (1 .. 128);
            Count    : Natural := 0;
            Read     : Natural;
            Plain_N  : constant Natural := Outcome.Prompt_Tokens;

            procedure Expect_Slices (Text : String) is
               Raw : Vocab.Token_Array (1 .. 128);
            begin
               Vocab.Encode (Words.all, Text, True, False, Raw, Read, Status);
               Assert (E.Is_Ok (Status), "the slice text did not tokenize");
               Count := 0;
               for Index in 1 .. Read loop
                  Count := Count + 1;
                  Expected (Count) := Raw (Index);
                  if Raw (Index) = Pictures.Marker then
                     for Row in 1 .. Per loop
                        Count := Count + 1;
                        Expected (Count) := Pictures.Soft;
                     end loop;
                     Count := Count + 1;
                     Expected (Count) := Pictures.Closer;
                  elsif Raw (Index) = Pictures.Slice_Marker then
                     for Row in 1 .. Per loop
                        Count := Count + 1;
                        Expected (Count) := Pictures.Soft;
                     end loop;
                     Count := Count + 1;
                     Expected (Count) := Pictures.Slice_Closer;
                  end if;
               end loop;
            end Expect_Slices;
         begin
            Pictures.Marker_Text := Model_Runner.Text.To_Bounded ("c");
            Pictures.Frame_Before := Model_Runner.Text.To_Bounded ("a");
            Pictures.Frame_After := Model_Runner.Text.Empty;
            Pictures.Slice_Marker := Vocab.Find (Words.all, "b");
            Pictures.Slice_Closer := Vocab.Find (Words.all, "<0x61>");
            Pictures.Slice_Marker_Text := Model_Runner.Text.To_Bounded ("b");
            Pictures.Slice_Row_End :=
              Model_Runner.Text.To_Bounded ([1 => ASCII.LF]);
            Pictures.Slice_Cols := new Gen.Crop_Counts'(1 => 1);
            Pictures.Crops := new Gen.Crop_Counts'(1 => 2);
            Assert (Pictures.Slice_Marker /= Vocab.No_Token
                    and then Pictures.Slice_Closer /= Vocab.No_Token
                    and then Pictures.Slice_Marker /= Pictures.Marker,
                    "the tiny vocabulary lacks the slice pieces this test needs");

            T.Free (Pictures.Rows);
            T.Allocate (3 * Per * Width, Pictures.Rows);
            Seed := 909;
            for Value of Pictures.Rows.all loop
               Value := Next;
            end loop;

            Expect_Slices ("ac" & "b" & ASCII.LF & "b");
            Assert (Count > Plain_N + Per,
                    "the overview and its slices opened nothing");

            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "c", Request, Stop, null, null, null, null, null,
               null, Pictures => Pictures, Outcome => Outcome);
            Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                    "the sliced picture run failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));
            Assert (Outcome.Prompt_Tokens = Count,
                    "the sliced prompt is" & Natural'Image (Outcome.Prompt_Tokens)
                    & " tokens, not" & Natural'Image (Count));
            for Index in 1 .. Count loop
               Assert (L.Committed_Token (Live, Index - 1) = Expected (Index),
                       "token" & Natural'Image (Index)
                       & " of the sliced prompt is "
                       & Vocab.Token_Id'Image (L.Committed_Token (Live, Index - 1))
                       & ", not " & Vocab.Token_Id'Image (Expected (Index)));
            end loop;

            Free (Pictures.Crops);
            Free (Pictures.Slice_Cols);
            Pictures.Slice_Marker := Vocab.No_Token;
            Pictures.Slice_Closer := Vocab.No_Token;
            Pictures.Marker_Text := Model_Runner.Text.Empty;
            Pictures.Frame_Before := Model_Runner.Text.Empty;
            Pictures.Frame_After := Model_Runner.Text.Empty;
            Pictures.Slice_Marker_Text := Model_Runner.Text.Empty;
            Pictures.Slice_Row_End := Model_Runner.Text.Empty;
         end;

         --  A MiniCPM-V video: its part stands as one mark, opened out
         --  into one picture marker a frame, each frame's rows behind the
         --  picture's soft token and closer. Here the mark is "b" and two
         --  frames, so "b" becomes "cc" and each "c" opens as a picture.
         declare
            Expected : Vocab.Token_Array (1 .. 128);
            Count    : Natural := 0;
            Read     : Natural;

            procedure Expect_Video (Text : String) is
               Raw : Vocab.Token_Array (1 .. 128);
            begin
               Vocab.Encode (Words.all, Text, True, False, Raw, Read, Status);
               Assert (E.Is_Ok (Status), "the video text did not tokenize");
               Count := 0;
               for Index in 1 .. Read loop
                  Count := Count + 1;
                  Expected (Count) := Raw (Index);
                  if Raw (Index) = Pictures.Marker then
                     for Row in 1 .. Per loop
                        Count := Count + 1;
                        Expected (Count) := Pictures.Soft;
                     end loop;
                     Count := Count + 1;
                     Expected (Count) := Pictures.Closer;
                  end if;
               end loop;
            end Expect_Video;
         begin
            Pictures.Marker_Text := Model_Runner.Text.To_Bounded ("c");
            Pictures.Video_As_Frames := True;
            Pictures.Video_Marker_Text := Model_Runner.Text.To_Bounded ("b");
            Pictures.Video_Slots := new Gen.Crop_Counts'(1 => 2);
            Pictures.Count := 2;
            T.Free (Pictures.Rows);
            T.Allocate (2 * Per * Width, Pictures.Rows);
            Seed := 313;
            for Value of Pictures.Rows.all loop
               Value := Next;
            end loop;

            Expect_Video ("cc");
            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "b", Request, Stop, null, null, null, null, null,
               null, Pictures => Pictures, Outcome => Outcome);
            Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                    "the video run failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));
            Assert (Outcome.Prompt_Tokens = Count,
                    "the video prompt is" & Natural'Image (Outcome.Prompt_Tokens)
                    & " tokens, not" & Natural'Image (Count));
            for Index in 1 .. Count loop
               Assert (L.Committed_Token (Live, Index - 1) = Expected (Index),
                       "token" & Natural'Image (Index)
                       & " of the video prompt is "
                       & Vocab.Token_Id'Image (L.Committed_Token (Live, Index - 1))
                       & ", not " & Vocab.Token_Id'Image (Expected (Index)));
            end loop;

            Free (Pictures.Video_Slots);
            Pictures.Video_As_Frames := False;
            Pictures.Video_Marker_Text := Model_Runner.Text.Empty;
            Pictures.Marker_Text := Model_Runner.Text.Empty;
            Pictures.Count := 1;
         end;

         --  Where the model numbers its pictures, each one's number is
         --  written ahead of it between the id markers, counted from zero:
         --  two pictures marked "c" become "a0a c" and "a1a c" (the id
         --  markers "a" here). The count check still sees two picture
         --  markers, since the id text is not one.
         declare
            Expected : Vocab.Token_Array (1 .. 128);
            Count    : Natural := 0;
            Read     : Natural;

            procedure Expect_Id (Text : String) is
               Raw : Vocab.Token_Array (1 .. 128);
            begin
               Vocab.Encode (Words.all, Text, True, False, Raw, Read, Status);
               Assert (E.Is_Ok (Status), "the numbered text did not tokenize");
               Count := 0;
               for Index in 1 .. Read loop
                  Count := Count + 1;
                  Expected (Count) := Raw (Index);
                  if Raw (Index) = Pictures.Marker then
                     for Row in 1 .. Per loop
                        Count := Count + 1;
                        Expected (Count) := Pictures.Soft;
                     end loop;
                     Count := Count + 1;
                     Expected (Count) := Pictures.Closer;
                  end if;
               end loop;
            end Expect_Id;
         begin
            Pictures.Marker_Text := Model_Runner.Text.To_Bounded ("c");
            Pictures.Frame_Before := Model_Runner.Text.Empty;
            Pictures.Frame_After := Model_Runner.Text.Empty;
            Pictures.Image_Id_Start := Model_Runner.Text.To_Bounded ("a");
            Pictures.Image_Id_End := Model_Runner.Text.To_Bounded ("a");
            Pictures.Count := 2;
            T.Free (Pictures.Rows);
            T.Allocate (2 * Per * Width, Pictures.Rows);
            Seed := 202;
            for Value of Pictures.Rows.all loop
               Value := Next;
            end loop;

            --  "cc" -> each "c" numbered: a0a c , a1a c.
            Expect_Id ("a0a" & "c" & "a1a" & "c");
            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "cc", Request, Stop, null, null, null, null, null,
               null, Pictures => Pictures, Outcome => Outcome);
            Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                    "the numbered run failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));
            Assert (Outcome.Prompt_Tokens = Count,
                    "the numbered prompt is"
                    & Natural'Image (Outcome.Prompt_Tokens) & " tokens, not"
                    & Natural'Image (Count));
            for Index in 1 .. Count loop
               Assert (L.Committed_Token (Live, Index - 1) = Expected (Index),
                       "token" & Natural'Image (Index)
                       & " of the numbered prompt is "
                       & Vocab.Token_Id'Image (L.Committed_Token (Live, Index - 1))
                       & ", not " & Vocab.Token_Id'Image (Expected (Index)));
            end loop;

            Pictures.Image_Id_Start := Model_Runner.Text.Empty;
            Pictures.Image_Id_End := Model_Runner.Text.Empty;
            Pictures.Marker_Text := Model_Runner.Text.Empty;
            Pictures.Count := 1;
         end;

         --  MiniCPM-V 2.5's older slice shape: the overview, then one group
         --  round all the slices, each slice its own picture marker, a line
         --  break between grid rows. Here the group markers are "a", the
         --  picture marker "c"; "c" becomes "c" (overview) "a" (group open)
         --  "c" (slice) line-break "c" (slice) "a" (group close).
         declare
            Expected : Vocab.Token_Array (1 .. 128);
            Count    : Natural := 0;
            Read     : Natural;

            procedure Expect_Group (Text : String) is
               Raw : Vocab.Token_Array (1 .. 128);
            begin
               Vocab.Encode (Words.all, Text, True, False, Raw, Read, Status);
               Assert (E.Is_Ok (Status), "the grouped text did not tokenize");
               Count := 0;
               for Index in 1 .. Read loop
                  Count := Count + 1;
                  Expected (Count) := Raw (Index);
                  if Raw (Index) = Pictures.Marker then
                     for Row in 1 .. Per loop
                        Count := Count + 1;
                        Expected (Count) := Pictures.Soft;
                     end loop;
                     Count := Count + 1;
                     Expected (Count) := Pictures.Closer;
                  end if;
               end loop;
            end Expect_Group;
         begin
            Pictures.Marker_Text := Model_Runner.Text.To_Bounded ("c");
            Pictures.Frame_Before := Model_Runner.Text.Empty;
            Pictures.Frame_After := Model_Runner.Text.Empty;
            --  Version-2 mode: no per-slice marker; the group wrappers, and
            --  each slice the picture marker.
            Pictures.Slice_Marker := Vocab.No_Token;
            Pictures.Slice_Marker_Text := Model_Runner.Text.To_Bounded ("c");
            Pictures.Slice_Group_Open := Model_Runner.Text.To_Bounded ("a");
            Pictures.Slice_Group_Close := Model_Runner.Text.To_Bounded ("a");
            Pictures.Slice_Row_End :=
              Model_Runner.Text.To_Bounded ([1 => ASCII.LF]);
            Pictures.Slice_Cols := new Gen.Crop_Counts'(1 => 1);
            Pictures.Crops := new Gen.Crop_Counts'(1 => 2);

            T.Free (Pictures.Rows);
            T.Allocate (3 * Per * Width, Pictures.Rows);
            Seed := 404;
            for Value of Pictures.Rows.all loop
               Value := Next;
            end loop;

            Expect_Group ("c" & "a" & "c" & ASCII.LF & "c" & "a");
            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "c", Request, Stop, null, null, null, null, null,
               null, Pictures => Pictures, Outcome => Outcome);
            Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                    "the grouped-slice run failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));
            Assert (Outcome.Prompt_Tokens = Count,
                    "the grouped prompt is"
                    & Natural'Image (Outcome.Prompt_Tokens) & " tokens, not"
                    & Natural'Image (Count));
            for Index in 1 .. Count loop
               Assert (L.Committed_Token (Live, Index - 1) = Expected (Index),
                       "token" & Natural'Image (Index)
                       & " of the grouped prompt is "
                       & Vocab.Token_Id'Image (L.Committed_Token (Live, Index - 1))
                       & ", not " & Vocab.Token_Id'Image (Expected (Index)));
            end loop;

            Free (Pictures.Crops);
            Free (Pictures.Slice_Cols);
            Pictures.Slice_Group_Open := Model_Runner.Text.Empty;
            Pictures.Slice_Group_Close := Model_Runner.Text.Empty;
            Pictures.Slice_Marker_Text := Model_Runner.Text.Empty;
            Pictures.Slice_Row_End := Model_Runner.Text.Empty;
            Pictures.Marker_Text := Model_Runner.Text.Empty;
         end;

         --  Two pictures given and one marked, or one given and none
         --  marked: refused before anything is evaluated.
         Pictures.Count := 2;
         L.Reset (Live);
         Gen.Release (Outcome);
         Gen.Generate
           (Ready, Live, "cab", Request, Stop, null, null, null, null, null,
            null, Pictures => Pictures, Outcome => Outcome);
         Assert (Gen."=" (Outcome.Reason, Gen.Runtime_Error)
                 and then Outcome.Error.Code = E.Generation_Picture_Count_Mismatch,
                 "two pictures for one marker were not refused");
         Pictures.Count := 1;
         L.Reset (Live);
         Gen.Release (Outcome);
         Gen.Generate
           (Ready, Live, "ab", Request, Stop, null, null, null, null, null,
            null, Pictures => Pictures, Outcome => Outcome);
         Assert (Gen."=" (Outcome.Reason, Gen.Runtime_Error)
                 and then Outcome.Error.Code = E.Generation_Picture_Count_Mismatch,
                 "a picture with no marker was not refused");

         Gen.Release (Outcome);
         Model_Runner.Stops.Close (Stop);
         T.Free (Pictures.Rows);
         L.Close (Live);
         L.Close (Ready, Status);
         Model_Runner.GGUF.Containers.Close (Parsed);
      end;

      B.Free (Image);
   end Pictures_Stand_Behind_Their_Markers;

   --  A video's slots stand among their seconds.
   --
   --  The template writes one marker for a video; the reference
   --  processor makes of it, for every pair of frames, the seconds the
   --  pair stands at and the pair's own marker between an opener and a
   --  closer, and each marker then opens out to the pair's rows as a
   --  picture's does. Here the tiny vocabulary's "a" is the picture
   --  marker and its own soft token, as Qwen's is, "b" the video's, and
   --  a line break the opener and closer: the prompt "ba" shows a video
   --  of two slots and then a picture -- that way round because "ab" is
   --  a piece of the vocabulary and "a" at the front takes the piece
   --  with the word boundary -- and the tokens committed are those of
   --  the rewritten text with every marker opened out, each slot's rows
   --  behind "b"s and the picture's behind "a"s, in the set's order. The
   --  seconds are written to one decimal with a half going to the even
   --  digit, which the first slot of a video at two frames a second turns
   --  on; and a prompt whose markers are not the set's kinds is refused.
   procedure A_Videos_Slots_Stand_Among_Their_Seconds
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Image : B.Byte_Array_Access;
   begin
      Assert (Gen.Seconds_Text (0.25) = "0.2"
              and then Gen.Seconds_Text (1.25) = "1.2"
              and then Gen.Seconds_Text (0.35) = "0.3"
              and then Gen.Seconds_Text (2.0) = "2.0"
              and then Gen.Seconds_Text (0.75) = "0.8"
              and then Gen.Seconds_Text (9.95) = "9.9"
              and then Gen.Seconds_Text (0.95) = "0.9"
              and then Gen.Seconds_Text (0.05) = "0.1"
              and then Gen.Seconds_Text (12.25) = "12.2"
              and then Gen.Seconds_Text (0.96) = "1.0"
              and then Gen.Seconds_Text (9.96) = "10.0"
              and then Gen.Seconds_Text (2.5) = "2.5"
              and then Gen.Seconds_Text (0.0) = "0.0"
              and then Gen.Seconds_Text (100.15) = "100.2",
              "the seconds are not written as the reference writes them: "
              & Gen.Seconds_Text (0.25) & " " & Gen.Seconds_Text (0.35) & " "
              & Gen.Seconds_Text (0.75) & " " & Gen.Seconds_Text (9.96) & " "
              & Gen.Seconds_Text (100.15));

      --  A video part is named as a picture is, by its type and path; a
      --  part of another type, or one with no path, names nothing.
      Assert (Model_Runner.CLI.Pictures.Names_A_Picture
                ("[{""type"": ""video"", ""path"": ""frames"", ""fps"": 2}, "
                 & "{""type"": ""text"", ""text"": ""?""}]"),
              "a video part was not seen as one");
      Assert (not Model_Runner.CLI.Pictures.Names_A_Picture
                ("[{""type"": ""video"", ""fps"": 2}, "
                 & "{""type"": ""audio"", ""path"": ""x""}]"),
              "a part with no path, or of another type, was taken for a video");

      Tiny_Model.Build (Image, Room => 128);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed : Model_Runner.GGUF.Containers.Container;
         Ready  : L.Model;
         Live   : L.Session;
         Status : E.Error_Info;
         Words  : access constant Vocab.Vocabulary;
         Pictures : Gen.Picture_Set;
         Request  : Gen.Request;
         Stop     : Model_Runner.Stops.Set;
         Outcome  : Gen.Result;
         Width    : constant N.Element_Count := Tiny_Model.Embedding;
         Per      : constant := 3;

         Expected : Vocab.Token_Array (1 .. 256);
         Count    : Natural := 0;

         --  The tokens of a text with every marker opened out: "a" to
         --  Per of itself, the k-th "b" to its slot's rows of itself.
         procedure Expect (Text : String) is
            Raw  : Vocab.Token_Array (1 .. 256);
            Read : Natural;
            Slot : Natural := 0;
         begin
            Vocab.Encode (Words.all, Text, True, False, Raw, Read, Status);
            Assert (E.Is_Ok (Status), "the expected text did not tokenize: "
                    & E.Error_Code'Image (Status.Code));
            Count := 0;
            for Index in 1 .. Read loop
               if Raw (Index) = Pictures.Marker then
                  for Row in 1 .. Per loop
                     Count := Count + 1;
                     Expected (Count) := Pictures.Soft;
                  end loop;
               elsif Raw (Index) = Pictures.Video_Marker then
                  Slot := Slot + 1;
                  for Row in 1 .. Pictures.Counts.all (Slot) loop
                     Count := Count + 1;
                     Expected (Count) := Pictures.Video_Marker;
                  end loop;
               else
                  Count := Count + 1;
                  Expected (Count) := Raw (Index);
               end if;
            end loop;
         end Expect;

         procedure Check (What : String) is
         begin
            Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                    "the run with " & What & " failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));
            Assert (Outcome.Prompt_Tokens = Count,
                    "the prompt with " & What & " is"
                    & Natural'Image (Outcome.Prompt_Tokens) & " tokens, not"
                    & Natural'Image (Count));
            for Index in 1 .. Count loop
               Assert (L.Committed_Token (Live, Index - 1) = Expected (Index),
                       "token" & Natural'Image (Index)
                       & " of the prompt with " & What & " is "
                       & Vocab.Token_Id'Image (L.Committed_Token (Live, Index - 1))
                       & ", not " & Vocab.Token_Id'Image (Expected (Index)));
            end loop;
         end Check;
      begin
         Model_Runner.GGUF.Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the tiny model did not parse");
         L.Prepare (Ready, Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the tiny model did not prepare");
         Words := L.Vocabulary (Ready);

         Pictures.Marker := Vocab.Find (Words.all, "a");
         Pictures.Soft := Pictures.Marker;
         Pictures.Closer := Vocab.No_Token;
         Pictures.Keep_Marker := False;
         Pictures.Causal_Rows := True;
         Pictures.Video_Marker := Vocab.Find (Words.all, "b");
         Pictures.Video_Marker_Text := Model_Runner.Text.To_Bounded ("b");
         --  A line break either side rather than a letter: "b" beside a
         --  "c" would vanish into the piece "bc".
         Pictures.Video_Open := Model_Runner.Text.To_Bounded ([1 => ASCII.LF]);
         Pictures.Video_Close := Model_Runner.Text.To_Bounded ([1 => ASCII.LF]);
         Assert (Pictures.Marker /= Vocab.No_Token
                 and then Pictures.Video_Marker /= Vocab.No_Token,
                 "the tiny vocabulary lacks the pieces this test needs");

         --  A video of two slots, of two and three rows, a quarter second
         --  and a second and a quarter in, then one still of Per rows.
         Pictures.Per_Picture := Per;
         Pictures.Count := 3;
         Pictures.Parts := 2;
         Pictures.Counts := new Gen.Crop_Counts'(2, 3, Per);
         Pictures.Kinds := new Gen.Entry_Kinds'(Gen.Slot, Gen.Slot, Gen.Still);
         Pictures.Video_Slots := new Gen.Crop_Counts'(1 => 2);
         Pictures.Times := new Gen.Slot_Times'(0.25, 1.25);
         T.Allocate ((Per + 5) * Width, Pictures.Rows);
         Seed := 777;
         for Value of Pictures.Rows.all loop
            Value := Next;
         end loop;

         Model_Runner.Stops.Open (Stop);
         Request.Max_Tokens := 4;
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
         Request.Seed := 1;
         Request.Has_Seed := True;
         Request.Add_Beginning := True;

         L.Open (Live, Ready, 128, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         --  "ba": the video opened out slot by slot, then the picture.
         Expect ("<0.2 seconds>" & ASCII.LF & "b" & ASCII.LF
                 & "<1.2 seconds>" & ASCII.LF & "b" & ASCII.LF & "a");
         Gen.Generate
           (Ready, Live, "ba", Request, Stop, null, null, null, null, null,
            null, Pictures => Pictures, Outcome => Outcome);
         Check ("a video and a picture");

         --  The same prompt with the same rows answers the same, and
         --  with other rows for the slots commits the same tokens: the
         --  rows are the slots' own and the words are not theirs.
         declare
            First_Text : constant String := Gen.Generated_Text (Outcome);
         begin
            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "ba", Request, Stop, null, null, null, null, null,
               null, Pictures => Pictures, Outcome => Outcome);
            Assert (Gen.Generated_Text (Outcome) = First_Text,
                    "the same video twice answered differently");

            for Value of Pictures.Rows.all (0 .. 5 * Width - 1) loop
               Value := Next * 8.0;
            end loop;
            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "ba", Request, Stop, null, null, null, null, null,
               null, Pictures => Pictures, Outcome => Outcome);
            Check ("other rows for the video");
         end;

         --  The set the other way round -- the still first, then the
         --  slots -- under the same prompt: the video's marker where the
         --  picture's should be, refused, since the set's rows would
         --  stand behind the wrong words.
         Pictures.Kinds.all := [Gen.Still, Gen.Slot, Gen.Slot];
         L.Reset (Live);
         Gen.Release (Outcome);
         Gen.Generate
           (Ready, Live, "ba", Request, Stop, null, null, null, null, null,
            null, Pictures => Pictures, Outcome => Outcome);
         Assert (Gen."=" (Outcome.Reason, Gen.Runtime_Error)
                 and then Outcome.Error.Code = E.Generation_Picture_Count_Mismatch,
                 "markers of the wrong kinds were not refused: "
                 & E.Error_Code'Image (Outcome.Error.Code));
         Pictures.Kinds.all := [Gen.Slot, Gen.Slot, Gen.Still];

         --  And "b" alone: a picture given and none marked.
         L.Reset (Live);
         Gen.Release (Outcome);
         Gen.Generate
           (Ready, Live, "b", Request, Stop, null, null, null, null, null,
            null, Pictures => Pictures, Outcome => Outcome);
         Assert (Gen."=" (Outcome.Reason, Gen.Runtime_Error)
                 and then Outcome.Error.Code = E.Generation_Picture_Count_Mismatch,
                 "a picture with no marker beside a video was not refused");

         Gen.Release (Outcome);
         Model_Runner.Stops.Close (Stop);
         Model_Runner.CLI.Pictures.Release (Pictures);
         L.Close (Live);
         L.Close (Ready, Status);
         Model_Runner.GGUF.Containers.Close (Parsed);
      end;

      B.Free (Image);
   end A_Videos_Slots_Stand_Among_Their_Seconds;

   ------------------------------------------------
   -- The_Qwen_Projector_Encodes_As_The_Reference --
   ------------------------------------------------

   --  The Qwen encoder's shape, written small: four-pixel patches walked
   --  in windows of two, a position grid of four a side, two heads of
   --  four -- one pair turned by the row and one by the column -- and a
   --  merger over a window's four rows.
   Patch_Q  : constant := 4;
   Merge_Q  : constant := 2;
   Grid_Q   : constant := 4;
   Width_Q  : constant := 8;
   Heads_Q  : constant := 2;
   Head_Q   : constant := Width_Q / Heads_Q;
   Feed_Q   : constant := 16;
   Blocks_Q : constant := 2;
   Text_Q   : constant := 12;
   Joined_Q : constant := Width_Q * Merge_Q * Merge_Q;
   Elements_Q : constant := 3 * Patch_Q * Patch_Q;
   Cells_Q  : constant := Grid_Q * Grid_Q;
   Triple_Q : constant := 3 * Width_Q;

   --  The picture: sixty-four by eighty, which is what sixty-four rows at
   --  least ask of a picture, so that the encoder resamples nothing and
   --  the reference reads the pixels as they are.
   Wide_Q   : constant := 64;
   Tall_Q   : constant := 80;
   Side_X_Q : constant := Wide_Q / Patch_Q;
   Side_Y_Q : constant := Tall_Q / Patch_Q;
   Patches_Q : constant := Side_X_Q * Side_Y_Q;
   Windows_X_Q : constant := Side_X_Q / Merge_Q;
   Windows_Y_Q : constant := Side_Y_Q / Merge_Q;
   Windows_Q : constant := Windows_X_Q * Windows_Y_Q;

   type Qwen_Block_Weights is record
      Ln1_W, Ln1_B, Ln2_W, Ln2_B : N.Real_Array (0 .. Width_Q - 1);
      QKV   : N.Real_Array (0 .. 3 * Width_Q * Width_Q - 1);  --  3 Width rows
      QKV_B : N.Real_Array (0 .. 3 * Width_Q - 1);
      O     : N.Real_Array (0 .. Width_Q * Width_Q - 1);
      O_B   : N.Real_Array (0 .. Width_Q - 1);
      Up    : N.Real_Array (0 .. Feed_Q * Width_Q - 1);
      Up_B  : N.Real_Array (0 .. Feed_Q - 1);
      Down  : N.Real_Array (0 .. Width_Q * Feed_Q - 1);
      Down_B : N.Real_Array (0 .. Width_Q - 1);
   end record;

   type Qwen_Block_List is array (0 .. Blocks_Q - 1) of Qwen_Block_Weights;

   type Qwen_Weights is record
      Patch_0, Patch_1 : N.Real_Array (0 .. Width_Q * Elements_Q - 1);
      Patch_B : N.Real_Array (0 .. Width_Q - 1);
      Pos     : N.Real_Array (0 .. Grid_Q * Grid_Q * Width_Q - 1);
      Blocks  : Qwen_Block_List;
      Post_W, Post_B : N.Real_Array (0 .. Width_Q - 1);
      MM0     : N.Real_Array (0 .. Joined_Q * Joined_Q - 1);
      MM0_B   : N.Real_Array (0 .. Joined_Q - 1);
      MM2     : N.Real_Array (0 .. Text_Q * Joined_Q - 1);  --  Text rows of Joined
      MM2_B   : N.Real_Array (0 .. Text_Q - 1);
   end record;

   type Qwen_Weights_Access is access Qwen_Weights;

   function Fresh_Qwen_Weights return Qwen_Weights_Access is
      W : constant Qwen_Weights_Access := new Qwen_Weights;
   begin
      Seed := 54321;
      W.Patch_0 := Random_Row (Width_Q * Elements_Q, 0.05);
      W.Patch_1 := Random_Row (Width_Q * Elements_Q, 0.05);
      W.Patch_B := Random_Row (Width_Q, 0.1);
      W.Pos := Random_Row (Grid_Q * Grid_Q * Width_Q, 0.3);
      for Index in W.Blocks'Range loop
         W.Blocks (Index).Ln1_W := Random_Row (Width_Q, 0.3);
         for Value of W.Blocks (Index).Ln1_W loop
            Value := Value + 1.0;
         end loop;
         W.Blocks (Index).Ln1_B := Random_Row (Width_Q, 0.1);
         W.Blocks (Index).Ln2_W := Random_Row (Width_Q, 0.3);
         for Value of W.Blocks (Index).Ln2_W loop
            Value := Value + 1.0;
         end loop;
         W.Blocks (Index).Ln2_B := Random_Row (Width_Q, 0.1);
         W.Blocks (Index).QKV := Random_Row (3 * Width_Q * Width_Q, 0.3);
         W.Blocks (Index).QKV_B := Random_Row (3 * Width_Q, 0.1);
         W.Blocks (Index).O := Random_Row (Width_Q * Width_Q, 0.3);
         W.Blocks (Index).O_B := Random_Row (Width_Q, 0.1);
         W.Blocks (Index).Up := Random_Row (Feed_Q * Width_Q, 0.3);
         W.Blocks (Index).Up_B := Random_Row (Feed_Q, 0.1);
         W.Blocks (Index).Down := Random_Row (Width_Q * Feed_Q, 0.2);
         W.Blocks (Index).Down_B := Random_Row (Width_Q, 0.1);
      end loop;
      W.Post_W := Random_Row (Width_Q, 0.3);
      for Value of W.Post_W loop
         Value := Value + 1.0;
      end loop;
      W.Post_B := Random_Row (Width_Q, 0.1);
      W.MM0 := Random_Row (Joined_Q * Joined_Q, 0.2);
      W.MM0_B := Random_Row (Joined_Q, 0.1);
      W.MM2 := Random_Row (Text_Q * Joined_Q, 0.2);
      W.MM2_B := Random_Row (Text_Q, 0.1);
      return W;
   end Fresh_Qwen_Weights;

   procedure Write_Qwen_Projector
     (Path : String; W : Qwen_Weights;
      Kind : String := "qwen3vl_merger") is
      Builder : Fixtures.Builder;
      File    : B.Byte_Array_Access;
      use Ada.Streams.Stream_IO;
      Handle  : File_Type;

      procedure Tensor
        (Name : String; Dims : Fixtures.Dimension_List; Values : N.Real_Array) is
      begin
         Fixtures.Add_Tensor
           (Builder, Name, Dims, G.Type_F32, Fixtures.Encode_F32 (Values));
      end Tensor;
   begin
      Fixtures.Reset (Builder);
      Fixtures.Add_String (Builder, "general.architecture", "clip");
      Fixtures.Add_String (Builder, "clip.projector_type", Kind);
      Fixtures.Add_U32 (Builder, "clip.vision.image_size", 768);
      Fixtures.Add_U32 (Builder, "clip.vision.patch_size", Patch_Q);
      Fixtures.Add_U32 (Builder, "clip.vision.embedding_length", Width_Q);
      Fixtures.Add_U32 (Builder, "clip.vision.feed_forward_length", Feed_Q);
      Fixtures.Add_U32 (Builder, "clip.vision.projection_dim", Text_Q);
      Fixtures.Add_U32 (Builder, "clip.vision.block_count", Blocks_Q);
      Fixtures.Add_U32 (Builder, "clip.vision.attention.head_count", Heads_Q);
      Fixtures.Add_U32 (Builder, "clip.vision.spatial_merge_size", Merge_Q);
      Fixtures.Add_F32
        (Builder, "clip.vision.attention.layer_norm_epsilon", 1.0e-6);
      Fixtures.Begin_Array
        (Builder, "clip.vision.image_mean", G.Value_Float32, 3);
      for Channel in 1 .. 3 loop
         Fixtures.Float_Element (Builder, 0.5);
      end loop;
      Fixtures.End_Array (Builder);
      Fixtures.Begin_Array
        (Builder, "clip.vision.image_std", G.Value_Float32, 3);
      for Channel in 1 .. 3 loop
         Fixtures.Float_Element (Builder, 0.5);
      end loop;
      Fixtures.End_Array (Builder);
      Fixtures.Begin_Array
        (Builder, "clip.vision.is_deepstack_layers", G.Value_Bool, Blocks_Q);
      for Index in 1 .. Blocks_Q loop
         Fixtures.Bool_Element (Builder, False);
      end loop;
      Fixtures.End_Array (Builder);

      Tensor ("v.patch_embd.weight", [Patch_Q, Patch_Q, 3, Width_Q], W.Patch_0);
      Tensor ("v.patch_embd.weight.1", [Patch_Q, Patch_Q, 3, Width_Q], W.Patch_1);
      Tensor ("v.patch_embd.bias", [Width_Q], W.Patch_B);
      Tensor ("v.position_embd.weight", [Width_Q, Cells_Q], W.Pos);
      for Index in W.Blocks'Range loop
         declare
            Prefix : constant String :=
              "v.blk." & Model_Runner.Text.Image (Long_Long_Integer (Index)) & ".";
            Current : Qwen_Block_Weights renames W.Blocks (Index);
         begin
            Tensor (Prefix & "ln1.weight", [Width_Q], Current.Ln1_W);
            Tensor (Prefix & "ln1.bias", [Width_Q], Current.Ln1_B);
            Tensor (Prefix & "ln2.weight", [Width_Q], Current.Ln2_W);
            Tensor (Prefix & "ln2.bias", [Width_Q], Current.Ln2_B);
            Tensor (Prefix & "attn_qkv.weight", [Width_Q, Triple_Q], Current.QKV);
            Tensor (Prefix & "attn_qkv.bias", [Triple_Q], Current.QKV_B);
            Tensor (Prefix & "attn_out.weight", [Width_Q, Width_Q], Current.O);
            Tensor (Prefix & "attn_out.bias", [Width_Q], Current.O_B);
            Tensor (Prefix & "ffn_up.weight", [Width_Q, Feed_Q], Current.Up);
            Tensor (Prefix & "ffn_up.bias", [Feed_Q], Current.Up_B);
            Tensor (Prefix & "ffn_down.weight", [Feed_Q, Width_Q], Current.Down);
            Tensor (Prefix & "ffn_down.bias", [Width_Q], Current.Down_B);
         end;
      end loop;
      Tensor ("v.post_ln.weight", [Width_Q], W.Post_W);
      Tensor ("v.post_ln.bias", [Width_Q], W.Post_B);
      Tensor ("mm.0.weight", [Joined_Q, Joined_Q], W.MM0);
      Tensor ("mm.0.bias", [Joined_Q], W.MM0_B);
      Tensor ("mm.2.weight", [Joined_Q, Text_Q], W.MM2);
      Tensor ("mm.2.bias", [Text_Q], W.MM2_B);

      Fixtures.Build (Builder, File);
      Create (Handle, Out_File, Path);
      declare
         Block : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (File.all'Length))
           with Import, Address => File.all'Address;
      begin
         Write (Handle, Block);
      end;
      Close (Handle);
      B.Free (File);
   end Write_Qwen_Projector;

   --  The rows the small Qwen projector should make of the picture, in
   --  binary64: the patches in window order, embedded by both frames'
   --  weights and placed by the grid interpolated with its corners
   --  aligned; the blocks, with the queries and keys turned by row and
   --  column; the post norm; and a window's four rows joined, through
   --  the merger's two steps. Given a Second frame, the rows of the pair
   --  the two make in a video: the first frame's pixels through the
   --  first temporal weights and the second's through the second, where
   --  a still is one frame through both.
   procedure Qwen_Reference_Rows
     (W : Qwen_Weights; Picture : Images.Raster; Rows : out N.Wide_Real_Array;
      Second : Images.Raster := (others => <>))
   is
      Paired : constant Boolean := Second.Pixels /= null;
      subtype WR is N.Wide_Real;
      type Matrix is array (0 .. Patches_Q - 1, 0 .. Width_Q - 1) of WR;
      type Wide_Matrix is array (0 .. Patches_Q - 1, 0 .. 3 * Width_Q - 1) of WR;
      X, H, A : Matrix;
      QKV : Wide_Matrix;
      F : array (0 .. Patches_Q - 1, 0 .. Feed_Q - 1) of WR;
      Row_Of, Column_Of : array (0 .. Patches_Q - 1) of Natural;

      function GELU (Value : WR) return WR
      is (0.5 * Value
          * (1.0 + Wide_Math.Tanh
                     (0.797_884_560_802_865_4
                      * (Value + 0.044_715 * Value * Value * Value))));

      --  The error function in binary64, by its series near zero and the
      --  continued fraction of its complement further out -- not the
      --  polynomial the kernel uses, so that the two are two computations.
      function Erf (X : WR) return WR is
         Z : constant WR := abs X;
         Result : WR;
      begin
         if Z < 2.5 then
            declare
               Term : WR := Z;
               Sum  : WR := Z;
               Z2   : constant WR := Z * Z;
            begin
               for K in 1 .. 60 loop
                  Term := -Term * Z2 / WR (K);
                  Sum := Sum + Term / WR (2 * K + 1);
               end loop;
               Result := 2.0 / Wide_Math.Sqrt (Ada.Numerics.Pi) * Sum;
            end;
         else
            --  erfc z = exp (-z^2) / sqrt (pi) / (z + 1/2 / (z + 1 / (z + 3/2 / (z + ...
            declare
               Fraction : WR := Z;
            begin
               for K in reverse 1 .. 60 loop
                  Fraction := Z + WR (K) / 2.0 / Fraction;
               end loop;
               Result := 1.0 - Wide_Math.Exp (-Z * Z)
                 / Wide_Math.Sqrt (Ada.Numerics.Pi) / Fraction;
            end;
         end if;
         return (if X < 0.0 then -Result else Result);
      end Erf;

      --  The unit itself, which the merger applies.
      function Exact_GELU (Value : WR) return WR
      is (0.5 * Value * (1.0 + Erf (Value * 0.707_106_781_186_547_5)));

      procedure Layer_Norm
        (Source : Matrix; Gain, Bias : N.Real_Array; Target : out Matrix) is
      begin
         for P in 0 .. Patches_Q - 1 loop
            declare
               Mean, Variance : WR := 0.0;
            begin
               for D in 0 .. Width_Q - 1 loop
                  Mean := Mean + Source (P, D);
               end loop;
               Mean := Mean / WR (Width_Q);
               for D in 0 .. Width_Q - 1 loop
                  Variance := Variance + (Source (P, D) - Mean) ** 2;
               end loop;
               Variance := Variance / WR (Width_Q);
               for D in 0 .. Width_Q - 1 loop
                  Target (P, D) :=
                    (Source (P, D) - Mean) / Wide_Math.Sqrt (Variance + 1.0e-6)
                    * WR (Gain (N.Element_Count (D))) + WR (Bias (N.Element_Count (D)));
               end loop;
            end;
         end loop;
      end Layer_Norm;

      --  The position grid at a patch's row and column, interpolated
      --  with the corners aligned.
      function Position (P, D : Natural) return WR is
         SY : constant WR :=
           WR (Row_Of (P)) * WR (Grid_Q - 1) / WR (Side_Y_Q - 1);
         SX : constant WR :=
           WR (Column_Of (P)) * WR (Grid_Q - 1) / WR (Side_X_Q - 1);
         Y0 : constant Natural := Natural (WR'Floor (SY));
         X0 : constant Natural := Natural (WR'Floor (SX));
         Y1 : constant Natural := Natural'Min (Grid_Q - 1, Y0 + 1);
         X1 : constant Natural := Natural'Min (Grid_Q - 1, X0 + 1);
         FY : constant WR := SY - WR (Y0);
         FX : constant WR := SX - WR (X0);
         function Cell (Y, X : Natural) return WR
         is (WR (W.Pos (N.Element_Count ((Y * Grid_Q + X) * Width_Q + D))));
      begin
         return (1.0 - FY) * (1.0 - FX) * Cell (Y0, X0)
           + (1.0 - FY) * FX * Cell (Y0, X1)
           + FY * (1.0 - FX) * Cell (Y1, X0)
           + FY * FX * Cell (Y1, X1);
      end Position;
   begin
      --  The walk: window by window, the four patches of each together.
      declare
         P : Natural := 0;
      begin
         for WY in 0 .. Windows_Y_Q - 1 loop
            for WX in 0 .. Windows_X_Q - 1 loop
               for DY in 0 .. Merge_Q - 1 loop
                  for DX in 0 .. Merge_Q - 1 loop
                     Row_Of (P) := WY * Merge_Q + DY;
                     Column_Of (P) := WX * Merge_Q + DX;
                     P := P + 1;
                  end loop;
               end loop;
            end loop;
         end loop;
      end;

      for P in 0 .. Patches_Q - 1 loop
         for R in 0 .. Width_Q - 1 loop
            declare
               Sum : WR := WR (W.Patch_B (N.Element_Count (R))) + Position (P, R);
            begin
               for C in 0 .. 2 loop
                  for KY in 0 .. Patch_Q - 1 loop
                     for KX in 0 .. Patch_Q - 1 loop
                        declare
                           Value : constant WR :=
                             (WR (Pixel (Picture, Column_Of (P) * Patch_Q + KX,
                                         Row_Of (P) * Patch_Q + KY, C)) / 255.0
                              - 0.5) / 0.5;
                           Other : constant WR :=
                             (if Paired
                              then (WR (Pixel (Second, Column_Of (P) * Patch_Q + KX,
                                                Row_Of (P) * Patch_Q + KY, C))
                                    / 255.0 - 0.5) / 0.5
                              else Value);
                           Index : constant N.Element_Count :=
                             N.Element_Count
                               (R * Elements_Q + C * Patch_Q * Patch_Q
                                + KY * Patch_Q + KX);
                        begin
                           Sum := Sum + Value * WR (W.Patch_0 (Index))
                             + Other * WR (W.Patch_1 (Index));
                        end;
                     end loop;
                  end loop;
               end loop;
               X (P, R) := Sum;
            end;
         end loop;
      end loop;

      for Index in W.Blocks'Range loop
         declare
            Current : Qwen_Block_Weights renames W.Blocks (Index);
            Pairs : constant Natural := Head_Q / 2;
            Half  : constant Natural := Pairs / 2;
         begin
            Layer_Norm (X, Current.Ln1_W, Current.Ln1_B, H);
            for P in 0 .. Patches_Q - 1 loop
               for R in 0 .. 3 * Width_Q - 1 loop
                  declare
                     Sum : WR := WR (Current.QKV_B (N.Element_Count (R)));
                  begin
                     for C in 0 .. Width_Q - 1 loop
                        Sum := Sum + H (P, C)
                          * WR (Current.QKV (N.Element_Count (R * Width_Q + C)));
                     end loop;
                     QKV (P, R) := Sum;
                  end;
               end loop;

               --  The rotation: the first half of a head's pairs by the
               --  row, the second by the column, each half counting its
               --  frequencies from the first; a pair is an element and
               --  the one half a head on.
               for Which in 0 .. 1 loop
                  for Hd in 0 .. Heads_Q - 1 loop
                     for Pair in 0 .. Pairs - 1 loop
                        declare
                           Start : constant Natural := Which * Width_Q + Hd * Head_Q;
                           Pos : constant Natural :=
                             (if Pair < Half then Row_Of (P) else Column_Of (P));
                           Freq : constant Natural :=
                             (if Pair < Half then Pair else Pair - Half);
                           Theta : constant WR :=
                             WR (Pos) * Wide_Math."**" (10_000.0, -2.0 * WR (Freq) / WR (Pairs));
                           C1 : constant WR := QKV (P, Start + Pair);
                           C2 : constant WR := QKV (P, Start + Pair + Pairs);
                        begin
                           QKV (P, Start + Pair) :=
                             C1 * Wide_Math.Cos (Theta) - C2 * Wide_Math.Sin (Theta);
                           QKV (P, Start + Pair + Pairs) :=
                             C1 * Wide_Math.Sin (Theta) + C2 * Wide_Math.Cos (Theta);
                        end;
                     end loop;
                  end loop;
               end loop;
            end loop;

            for Hd in 0 .. Heads_Q - 1 loop
               for P in 0 .. Patches_Q - 1 loop
                  declare
                     Scores : array (0 .. Patches_Q - 1) of WR;
                     Largest, Total : WR;
                  begin
                     for O in 0 .. Patches_Q - 1 loop
                        Scores (O) := 0.0;
                        for D in 0 .. Head_Q - 1 loop
                           Scores (O) := Scores (O)
                             + QKV (P, Hd * Head_Q + D)
                               * QKV (O, Width_Q + Hd * Head_Q + D);
                        end loop;
                        Scores (O) := Scores (O) / Wide_Math.Sqrt (WR (Head_Q));
                     end loop;
                     Largest := Scores (0);
                     for O in 1 .. Patches_Q - 1 loop
                        Largest := WR'Max (Largest, Scores (O));
                     end loop;
                     Total := 0.0;
                     for O in 0 .. Patches_Q - 1 loop
                        Scores (O) := Wide_Math.Exp (Scores (O) - Largest);
                        Total := Total + Scores (O);
                     end loop;
                     for D in 0 .. Head_Q - 1 loop
                        declare
                           Sum : WR := 0.0;
                        begin
                           for O in 0 .. Patches_Q - 1 loop
                              Sum := Sum + Scores (O) / Total
                                * QKV (O, 2 * Width_Q + Hd * Head_Q + D);
                           end loop;
                           A (P, Hd * Head_Q + D) := Sum;
                        end;
                     end loop;
                  end;
               end loop;
            end loop;

            for P in 0 .. Patches_Q - 1 loop
               for R in 0 .. Width_Q - 1 loop
                  declare
                     Sum : WR := WR (Current.O_B (N.Element_Count (R)));
                  begin
                     for C in 0 .. Width_Q - 1 loop
                        Sum := Sum + A (P, C)
                          * WR (Current.O (N.Element_Count (R * Width_Q + C)));
                     end loop;
                     X (P, R) := X (P, R) + Sum;
                  end;
               end loop;
            end loop;

            Layer_Norm (X, Current.Ln2_W, Current.Ln2_B, H);
            for P in 0 .. Patches_Q - 1 loop
               for R in 0 .. Feed_Q - 1 loop
                  declare
                     Sum : WR := WR (Current.Up_B (N.Element_Count (R)));
                  begin
                     for C in 0 .. Width_Q - 1 loop
                        Sum := Sum + H (P, C)
                          * WR (Current.Up (N.Element_Count (R * Width_Q + C)));
                     end loop;
                     F (P, R) := GELU (Sum);
                  end;
               end loop;
               for R in 0 .. Width_Q - 1 loop
                  declare
                     Sum : WR := WR (Current.Down_B (N.Element_Count (R)));
                  begin
                     for C in 0 .. Feed_Q - 1 loop
                        Sum := Sum + F (P, C)
                          * WR (Current.Down (N.Element_Count (R * Feed_Q + C)));
                     end loop;
                     X (P, R) := X (P, R) + Sum;
                  end;
               end loop;
            end loop;
         end;
      end loop;

      Layer_Norm (X, W.Post_W, W.Post_B, H);

      --  The merger: a window's four rows, in the walk's order, as one.
      for Window in 0 .. Windows_Q - 1 loop
         declare
            Joined, Middle : array (0 .. Joined_Q - 1) of WR;
         begin
            for K in 0 .. Merge_Q * Merge_Q - 1 loop
               for D in 0 .. Width_Q - 1 loop
                  Joined (K * Width_Q + D) := H (Window * Merge_Q * Merge_Q + K, D);
               end loop;
            end loop;
            for R in 0 .. Joined_Q - 1 loop
               declare
                  Sum : WR := WR (W.MM0_B (N.Element_Count (R)));
               begin
                  for C in 0 .. Joined_Q - 1 loop
                     Sum := Sum + Joined (C) * WR (W.MM0 (N.Element_Count (R * Joined_Q + C)));
                  end loop;
                  Middle (R) := Exact_GELU (Sum);
               end;
            end loop;
            for J in 0 .. Text_Q - 1 loop
               declare
                  Sum : WR := WR (W.MM2_B (N.Element_Count (J)));
               begin
                  for C in 0 .. Joined_Q - 1 loop
                     Sum := Sum + Middle (C) * WR (W.MM2 (N.Element_Count (J * Joined_Q + C)));
                  end loop;
                  Rows (N.Element_Count (Window * Text_Q + J)) := Sum;
               end;
            end loop;
         end;
      end loop;
   end Qwen_Reference_Rows;

   --  The small Qwen projector, written and opened, encodes a picture to
   --  the rows the plain computation gives, as a grid of the picture's
   --  windows; and the cubic filter resamples as PIL does.
   procedure The_Qwen_Projector_Encodes_As_The_Reference
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      W : constant Qwen_Weights_Access := Fresh_Qwen_Weights;
      Picture : Images.Raster;
      Status  : E.Error_Info;
      Wanted  : N.Wide_Real_Array (0 .. Windows_Q * Text_Q - 1);
      Rows    : T.Real_Array_Access;
      Grid_Rows, Grid_Columns : Natural;
      Eyes    : Vision.Encoder;
   begin
      declare
         Data : B.Byte_Array (1 .. 3 * Wide_Q * Tall_Q);
      begin
         for Y in 0 .. Tall_Q - 1 loop
            for X in 0 .. Wide_Q - 1 loop
               declare
                  At_Pixel : constant B.Byte_Count :=
                    B.Byte_Count (3 * (Y * Wide_Q + X)) + 1;
               begin
                  Data (At_Pixel) := B.Byte (X * 3);
                  Data (At_Pixel + 1) := B.Byte (Y * 3);
                  Data (At_Pixel + 2) :=
                    (if X in 20 .. 44 and then Y in 24 .. 56 then 240 else 30);
               end;
            end loop;
         end loop;
         Images.Decode
           (Bytes_Of ("P6 64 80 255 ") & Data, "test", Picture, Status);
         Assert (E.Is_Ok (Status), "the test picture was refused");
      end;

      Qwen_Reference_Rows (W.all, Picture, Wanted);

      Write_Qwen_Projector ("obj/vision-qwen.gguf", W.all);
      Vision.Open (Eyes, "obj/vision-qwen.gguf", Status);
      Assert (E.Is_Ok (Status), "the small Qwen projector did not open: "
              & E.Error_Code'Image (Status.Code));
      Assert (Vision.Is_Ready (Eyes)
              and then not Vision.Fixed_Rows (Eyes)
              and then Vision.Placed_Rows (Eyes)
              and then Vision.Row_Width (Eyes) = Text_Q
              and then Vision.Projector (Eyes) = "qwen3vl_merger",
              "the small Qwen projector's shape was misread");

      Vision.Encode (Eyes, Picture, null, Rows, Grid_Rows, Grid_Columns,
                     Status => Status);
      Assert (E.Is_Ok (Status), "the small Qwen projector did not encode: "
              & E.Error_Code'Image (Status.Code));
      Assert (Grid_Rows = Windows_Y_Q and then Grid_Columns = Windows_X_Q,
              "the grid is" & Natural'Image (Grid_Rows) & " by"
              & Natural'Image (Grid_Columns) & ", not"
              & Natural'Image (Windows_Y_Q) & " by" & Natural'Image (Windows_X_Q));
      Assert (Rows /= null and then Rows.all'Length = Windows_Q * Text_Q,
              "the encoder made the wrong number of rows");
      for J in 0 .. N.Element_Count (Windows_Q * Text_Q - 1) loop
         Assert (abs (N.Wide_Real (Rows (J)) - Wanted (J))
                 <= 1.0e-4 * (1.0 + abs Wanted (J)),
                 "row element" & N.Element_Count'Image (J) & " is "
                 & N.Real'Image (Rows (J)) & " where the reference has "
                 & N.Wide_Real'Image (Wanted (J)));
      end loop;
      T.Free (Rows);

      --  A picture too small for the least rows is scaled up to them,
      --  by the reference's rule: twenty by thirty, at sixty-four rows
      --  of eight pixels a side, is fifty-six by eighty.
      declare
         Small : Images.Raster;
      begin
         Images.Resample (Picture, 20, 30, Small);
         Vision.Encode (Eyes, Small, null, Rows, Grid_Rows, Grid_Columns,
                        Status => Status);
         Assert (E.Is_Ok (Status), "the small picture did not encode");
         Assert (Grid_Rows = 10 and then Grid_Columns = 7,
                 "a small picture's grid is" & Natural'Image (Grid_Rows)
                 & " by" & Natural'Image (Grid_Columns) & ", not 10 by 7");
         T.Free (Rows);
         Images.Free (Small);
      end;
      Vision.Close (Eyes);

      --  Qwen2-VL's merger is the same shape read under a name of its own,
      --  its deepstack the one thing Qwen3-VL adds and this leaves out, so
      --  the same weights written under it encode a picture to the same
      --  rows: the reference the sweep already computed.
      Write_Qwen_Projector
        ("obj/vision-qwen.gguf", W.all, Kind => "qwen2vl_merger");
      Vision.Open (Eyes, "obj/vision-qwen.gguf", Status);
      Assert (E.Is_Ok (Status), "the Qwen2-VL projector did not open: "
              & E.Error_Code'Image (Status.Code));
      Assert (Vision.Projector (Eyes) = "qwen2vl_merger",
              "the Qwen2-VL projector's kind was misread");
      Vision.Encode (Eyes, Picture, null, Rows, Grid_Rows, Grid_Columns,
                     Status => Status);
      Assert (E.Is_Ok (Status), "the Qwen2-VL projector did not encode: "
              & E.Error_Code'Image (Status.Code));
      Assert (Rows /= null and then Rows.all'Length = Windows_Q * Text_Q,
              "the Qwen2-VL encoder made the wrong number of rows");
      for J in 0 .. N.Element_Count (Windows_Q * Text_Q - 1) loop
         Assert (abs (N.Wide_Real (Rows (J)) - Wanted (J))
                 <= 1.0e-4 * (1.0 + abs Wanted (J)),
                 "Qwen2-VL row element" & N.Element_Count'Image (J)
                 & " is " & N.Real'Image (Rows (J)) & " where the reference "
                 & "has " & N.Wide_Real'Image (Wanted (J)));
      end loop;
      T.Free (Rows);
      Vision.Close (Eyes);

      --  The cubic filter: a two-pixel row 0 and 200 stretched to four
      --  is 0, 41, 159, 218, what PIL's BICUBIC gives -- the last pixel
      --  past 200 is the cubic's overshoot at a step, and the triangle
      --  would never leave the range.
      declare
         Source, Result : Images.Raster;
      begin
         Images.Decode
           (Bytes_Of ("P5 2 1 255 ") & [0, 200], "test", Source, Status);
         Images.Resample (Source, 4, 1, Result, Images.Cubic);
         Assert (Result.Width = 4
                 and then Pixel (Result, 0, 0, 0) = 0
                 and then Pixel (Result, 1, 0, 0) in 40 .. 42
                 and then Pixel (Result, 2, 0, 0) in 158 .. 160
                 and then Pixel (Result, 3, 0, 0) in 217 .. 219,
                 "the cubic stretch is not PIL's:"
                 & Natural'Image (Pixel (Result, 0, 0, 0))
                 & Natural'Image (Pixel (Result, 1, 0, 0))
                 & Natural'Image (Pixel (Result, 2, 0, 0))
                 & Natural'Image (Pixel (Result, 3, 0, 0)));
         Images.Free (Result);
         Images.Free (Source);
      end;

      Images.Free (Picture);
   end The_Qwen_Projector_Encodes_As_The_Reference;

   --  A pair of frames encodes as the reference: the first frame through
   --  the first temporal weights and the second through the second, where
   --  a still is one frame through both -- so a frame paired with itself
   --  is the still, to the rounding, and paired with another is not.
   --  And the fit a video's frames are resampled to follows the reference
   --  video processor's rule: the sides to multiples of the window, the
   --  pixels over the frames held between the least and the most with
   --  each frame capped, a side under the window scaled up first, and
   --  sides two hundred to one refused. Gemma 3's projector reads no
   --  video and says so by name.
   procedure A_Pair_Of_Frames_Encodes_As_The_Reference
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      W : constant Qwen_Weights_Access := Fresh_Qwen_Weights;
      First, Second : Images.Raster;
      Status  : E.Error_Info;
      Wanted  : N.Wide_Real_Array (0 .. Windows_Q * Text_Q - 1);
      Still, Pair, Same : T.Real_Array_Access;
      Grid_Rows, Grid_Columns : Natural;
      Fit_Width, Fit_Height : Positive;
      Eyes    : Vision.Encoder;

      --  Two frames: a gradient with a bright block, and the same with
      --  the block moved.
      procedure Draw (Into : out Images.Raster; Shift : Natural) is
         Data : B.Byte_Array (1 .. 3 * Wide_Q * Tall_Q);
      begin
         for Y in 0 .. Tall_Q - 1 loop
            for X in 0 .. Wide_Q - 1 loop
               declare
                  At_Pixel : constant B.Byte_Count :=
                    B.Byte_Count (3 * (Y * Wide_Q + X)) + 1;
               begin
                  Data (At_Pixel) := B.Byte (X * 3);
                  Data (At_Pixel + 1) := B.Byte (Y * 3);
                  Data (At_Pixel + 2) :=
                    (if X in 20 + Shift .. 44 + Shift and then Y in 24 .. 56
                     then 240 else 30);
               end;
            end loop;
         end loop;
         Images.Decode
           (Bytes_Of ("P6 64 80 255 ") & Data, "test", Into, Status);
         Assert (E.Is_Ok (Status), "the test frame was refused");
      end Draw;

      --  The fit the encoder picks for frames of a size, against the
      --  reference's rule worked by hand at this projector's window of
      --  eight pixels.
      procedure Fits
        (Width, Height, Frames : Positive; Want_Width, Want_Height : Positive)
      is
         Got_Width, Got_Height : Positive;
         Local : E.Error_Info;
      begin
         Vision.Frames_Fit
           (Eyes, Width, Height, Frames, Got_Width, Got_Height, Local);
         Assert (E.Is_Ok (Local), "the fit of" & Width'Image & " x"
                 & Height'Image & " over" & Frames'Image & " frames was refused");
         Assert (Got_Width = Want_Width and then Got_Height = Want_Height,
                 "the fit of" & Width'Image & " x" & Height'Image & " over"
                 & Frames'Image & " frames is" & Got_Width'Image & " x"
                 & Got_Height'Image & ", not" & Want_Width'Image & " x"
                 & Want_Height'Image);
      end Fits;
   begin
      Draw (First, 0);
      Draw (Second, 12);

      Write_Qwen_Projector ("obj/vision-qwen.gguf", W.all);
      Vision.Open (Eyes, "obj/vision-qwen.gguf", Status);
      Assert (E.Is_Ok (Status), "the small Qwen projector did not open: "
              & E.Error_Code'Image (Status.Code));
      Assert (Vision.Reads_Video (Eyes), "the Qwen projector reads no video");

      --  The rule, at the window of eight: sixty-four by eighty over two
      --  frames stands; twenty by thirty over one is scaled up to the
      --  least pixels; five by five is scaled to the window first and
      --  then up; a thousand by twenty rounds to sixteen tall and stands
      --  as fifty to one; six hundred and forty by four hundred and eighty
      --  over forty frames is cut to the frames' cap; and two thousand
      --  by nine is refused as past two hundred to one.
      Fits (64, 80, 2, 64, 80);
      Fits (20, 30, 1, 56, 80);
      Fits (5, 5, 3, 40, 40);
      Fits (1000, 20, 2, 1000, 16);
      Fits (640, 480, 40, 256, 192);
      Vision.Frames_Fit (Eyes, 2000, 9, 2, Fit_Width, Fit_Height, Status);
      Assert (Status.Code = E.Arch_Unsupported_Feature,
              "frames two hundred to one were not refused");

      Vision.Frames_Fit (Eyes, Wide_Q, Tall_Q, 2, Fit_Width, Fit_Height, Status);
      Assert (E.Is_Ok (Status) and then Fit_Width = Wide_Q
              and then Fit_Height = Tall_Q, "the test frames' fit moved");

      --  The pair against the reference.
      Qwen_Reference_Rows (W.all, First, Wanted, Second);
      Vision.Encode_Frames
        (Eyes, First, Second, Fit_Width, Fit_Height, null, Pair, Grid_Rows,
         Grid_Columns, Status => Status);
      Assert (E.Is_Ok (Status), "the pair did not encode: "
              & E.Error_Code'Image (Status.Code));
      Assert (Grid_Rows = Windows_Y_Q and then Grid_Columns = Windows_X_Q,
              "the pair's grid is" & Natural'Image (Grid_Rows) & " by"
              & Natural'Image (Grid_Columns));
      for J in 0 .. N.Element_Count (Windows_Q * Text_Q - 1) loop
         Assert (abs (N.Wide_Real (Pair (J)) - Wanted (J))
                 <= 1.0e-4 * (1.0 + abs Wanted (J)),
                 "pair element" & N.Element_Count'Image (J) & " is "
                 & N.Real'Image (Pair (J)) & " where the reference has "
                 & N.Wide_Real'Image (Wanted (J)));
      end loop;

      --  A frame paired with itself is the still; paired with the other,
      --  it is not.
      Vision.Encode (Eyes, First, null, Still, Grid_Rows, Grid_Columns,
                     Status => Status);
      Assert (E.Is_Ok (Status), "the still did not encode");
      Vision.Encode_Frames
        (Eyes, First, First, Fit_Width, Fit_Height, null, Same, Grid_Rows,
         Grid_Columns, Status => Status);
      Assert (E.Is_Ok (Status), "the frame paired with itself did not encode");
      declare
         Apart_Same, Apart_Pair : N.Wide_Real := 0.0;
      begin
         for J in Still.all'Range loop
            Apart_Same := N.Wide_Real'Max
              (Apart_Same, abs (N.Wide_Real (Still (J)) - N.Wide_Real (Same (J))));
            Apart_Pair := N.Wide_Real'Max
              (Apart_Pair, abs (N.Wide_Real (Still (J)) - N.Wide_Real (Pair (J))));
         end loop;
         Assert (Apart_Same <= 1.0e-4,
                 "a frame paired with itself is" & N.Wide_Real'Image (Apart_Same)
                 & " from the still");
         Assert (Apart_Pair > 1.0e-2,
                 "a frame paired with another is only"
                 & N.Wide_Real'Image (Apart_Pair) & " from the still");
      end;

      T.Free (Still);
      T.Free (Pair);
      T.Free (Same);
      Vision.Close (Eyes);
      Images.Free (First);
      Images.Free (Second);

      --  And Gemma 3's projector, which reads no video.
      declare
         Gemma : Vision.Encoder;
         G : constant Projector_Weights_Access := Fresh_Weights;
      begin
         Write_Projector ("obj/vision-small.gguf", G.all, False);
         Vision.Open (Gemma, "obj/vision-small.gguf", Status);
         Assert (E.Is_Ok (Status), "the small Gemma projector did not open");
         Assert (not Vision.Reads_Video (Gemma), "Gemma's projector reads video");
         Vision.Frames_Fit (Gemma, 64, 80, 2, Fit_Width, Fit_Height, Status);
         Assert (Status.Code = E.Arch_Unsupported_Feature,
                 "a video's fit on Gemma's projector was not refused by name");
         Vision.Close (Gemma);
      end;
   end A_Pair_Of_Frames_Encodes_As_The_Reference;

   --  A video's frames are fetched as the reference takes them.
   --
   --  The sampling rule, worked against numpy's linspace and round: a
   --  video's length times the rate, cut to whole frames, held between
   --  four and seven hundred and sixty-eight and never above the frames
   --  there are, spread evenly from the first frame to the last with a
   --  half going to the even one. Then Fetch: a directory of three
   --  pictures comes back as three frames at the fit, at nought, a half
   --  and one second at two a second; and, where the host has the
   --  libraries, a four-frame video written as YUV4MPEG -- which
   --  libavformat reads without any codec -- is decoded to four frames
   --  whose grey rises frame by frame, counted from its packets since the
   --  container states no count, at its own rate of two a second, and
   --  sampled to all four; a file that is not a video is refused by name,
   --  and one that is not there as not there. Without the libraries the
   --  file is refused by name and the rest is not asked.
   procedure A_Videos_Frames_Are_Fetched_As_The_Reference_Takes_Them
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use type Model_Runner.Video.Frame_Indices;
      use type Model_Runner.Video.Raster_List_Access;
      use type Model_Runner.Video.Seconds_List_Access;

      W : constant Qwen_Weights_Access := Fresh_Qwen_Weights;
      Eyes   : Vision.Encoder;
      Status : E.Error_Info;
      Kept   : Model_Runner.Video.Raster_List_Access;
      Times  : Model_Runner.Video.Seconds_List_Access;
      Fit_Width, Fit_Height : Positive;

      --  A file of bytes, written whole.
      procedure Write_File (Path : String; Data : B.Byte_Array) is
         use Ada.Streams.Stream_IO;
         Handle : File_Type;
      begin
         Create (Handle, Out_File, Path);
         B.Byte_Array'Write (Stream (Handle), Data);
         Close (Handle);
      end Write_File;
   begin
      --  The count, and the frames.
      Assert (Model_Runner.Video.Sampled_Count (75, 25.0, 2.0) = 6
              and then Model_Runner.Video.Sampled_Count (3, 25.0, 2.0) = 3
              and then Model_Runner.Video.Sampled_Count (10, 1.0, 2.0) = 10
              and then Model_Runner.Video.Sampled_Count (5, 25.0, 2.0) = 4
              and then Model_Runner.Video.Sampled_Count (100, 100.0, 2.0) = 4
              and then Model_Runner.Video.Sampled_Count (2000, 25.0, 2.0) = 160
              and then Model_Runner.Video.Sampled_Count (100_000, 25.0, 2.0)
                       = 768,
              "the frames taken of a video are not the reference's count");
      Assert (Model_Runner.Video.Sampled (75, 6) = [0, 15, 30, 44, 59, 74]
              and then Model_Runner.Video.Sampled (3, 3) = [0, 1, 2]
              and then Model_Runner.Video.Sampled (5, 4) = [0, 1, 3, 4]
              and then Model_Runner.Video.Sampled (100, 4) = [0, 33, 66, 99]
              and then Model_Runner.Video.Sampled (6, 3) = [0, 2, 5]
              and then Model_Runner.Video.Sampled (1, 1) = [1 => 0]
              and then Model_Runner.Video.Sampled (2, 4) = [0, 0, 1, 1],
              "the frames taken of a video are not the reference's frames");
      declare
         Long : constant Model_Runner.Video.Frame_Indices :=
           Model_Runner.Video.Sampled (2000, 160);
      begin
         Assert (Long (1 .. 8) = [0, 13, 25, 38, 50, 63, 75, 88]
                 and then Long (158 .. 160) = [1974, 1986, 1999],
                 "a long video's frames are not the reference's");
      end;

      Write_Qwen_Projector ("obj/vision-qwen.gguf", W.all);
      Vision.Open (Eyes, "obj/vision-qwen.gguf", Status);
      Assert (E.Is_Ok (Status), "the small Qwen projector did not open");

      --  A directory of three pictures, twenty by thirty, at two a second.
      Ada.Directories.Create_Path ("obj/video-frames");
      for Which in 1 .. 3 loop
         declare
            Data : constant B.Byte_Array (1 .. 3 * 20 * 30) :=
              [others => B.Byte (40 * Which)];
         begin
            Write_File
              ("obj/video-frames/f" & Character'Val (Character'Pos ('0') + Which)
               & ".ppm",
               Bytes_Of ("P6 20 30 255 ") & Data);
         end;
      end loop;
      Model_Runner.Video.Fetch
        ("obj/video-frames", 2.0, Eyes, Kept, Times, Fit_Width, Fit_Height,
         Status);
      Assert (E.Is_Ok (Status), "the frames were not fetched: "
              & E.Error_Code'Image (Status.Code));
      Assert (Kept /= null and then Kept.all'Length = 3
              and then Times /= null
              and then Times.all (1) = 0.0 and then Times.all (2) = 0.5
              and then Times.all (3) = 1.0,
              "three frames at two a second are not three at nought, a "
              & "half and one");
      Assert (Fit_Width = 32 and then Fit_Height = 48
              and then Kept.all (1).Width = 32 and then Kept.all (1).Height = 48
              and then Kept.all (3).Width = 32,
              "the frames were not fitted together:" & Fit_Width'Image
              & " x" & Fit_Height'Image);
      Model_Runner.Video.Release (Kept, Times);

      --  A file that is not there, and one that is not a video.
      Model_Runner.Video.Fetch
        ("obj/no-such-video.mp4", 2.0, Eyes, Kept, Times, Fit_Width,
         Fit_Height, Status);
      Assert (Status.Code = E.IO_Open_Failed,
              "a video that is not there was not refused as not there: "
              & E.Error_Code'Image (Status.Code));
      Model_Runner.Video.Fetch
        ("obj/vision-qwen.gguf", 2.0, Eyes, Kept, Times, Fit_Width, Fit_Height,
         Status);
      Assert (Status.Code = E.IO_Video_Unreadable,
              "a file that is not a video was not refused by name: "
              & E.Error_Code'Image (Status.Code));

      if Model_Runner.Platform.Video.Is_Supported then
         --  Four frames of sixteen by sixteen, the grey rising: YUV4MPEG,
         --  the header, then each frame's luma, and its two chroma planes
         --  at half the size, all at the middle.
         declare
            Header : constant String :=
              "YUV4MPEG2 W16 H16 F2:1 Ip A1:1 C420jpeg" & ASCII.LF;
            Frame_Header : constant String := "FRAME" & ASCII.LF;
            Video : B.Byte_Array
              (1 .. B.Byte_Count (Header'Length
                                  + 4 * (Frame_Header'Length + 256 + 64 + 64)));
            Here : B.Byte_Count := 1;

            procedure Put (Data : B.Byte_Array) is
            begin
               Video (Here .. Here + Data'Length - 1) := Data;
               Here := Here + Data'Length;
            end Put;
         begin
            Put (Bytes_Of (Header));
            for Which in 0 .. 3 loop
               Put (Bytes_Of (Frame_Header));
               Put ([1 .. 256 => B.Byte (40 + 50 * Which)]);
               Put ([1 .. 128 => 128]);
            end loop;
            Write_File ("obj/video-tiny.y4m", Video);
         end;

         Model_Runner.Video.Fetch
           ("obj/video-tiny.y4m", 2.0, Eyes, Kept, Times, Fit_Width, Fit_Height,
            Status);
         Assert (E.Is_Ok (Status), "the video file was not fetched: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Kept /= null and then Kept.all'Length = 4,
                 "four frames at two a second, sampled at two a second, are"
                 & " not four");
         Assert (Times.all (1) = 0.0 and then Times.all (2) = 0.5
                 and then Times.all (4) = 1.5,
                 "the decoded frames' seconds are not their numbers over the"
                 & " rate");
         --  Sixteen by sixteen, over four frames, is under the least
         --  pixels and scaled up by the rule; and the grey of each frame
         --  is above the one before.
         Assert (Fit_Width = 32 and then Fit_Height = 32,
                 "the decoded frames' fit is" & Fit_Width'Image & " x"
                 & Fit_Height'Image & ", not 32 x 32");
         for Which in 1 .. 3 loop
            Assert (Pixel (Kept.all (Which + 1), 8, 8, 0)
                    > Pixel (Kept.all (Which), 8, 8, 0) + 20,
                    "frame" & Which'Image & " is not darker than the next");
         end loop;
         Model_Runner.Video.Release (Kept, Times);
      end if;

      Vision.Close (Eyes);
   end A_Videos_Frames_Are_Fetched_As_The_Reference_Takes_Them;

   ---------------------------------------
   -- Placed_Rows_Turn_By_Row_And_Column --
   ---------------------------------------

   --  A model whose positions have three parts turns a picture's rows by
   --  where they stand: the picture's start for time, its own row and
   --  column for the rest, and the text after the picture goes on from
   --  the start plus the grid's longer side. A Qwen35 fixture stating
   --  its sections is given a picture of two rows by two, and what each
   --  position turned by is read back -- and the logits at the end differ
   --  from those of the same batch with no places, which take the index.
   --  A rewind keeps the marks, and a snapshot carries them. (A shift
   --  would move them, but the one family with three-part positions is a
   --  hybrid, which cannot shift.)
   procedure Placed_Rows_Turn_By_Row_And_Column
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image, Kind => Tiny_Model.Qwen35, Room => 32,
                        Sections => True);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed : Model_Runner.GGUF.Containers.Container;
         Ready  : L.Model;
         Live   : L.Session;
         Status : E.Error_Info;
         Words  : access constant Vocab.Vocabulary;
         Width  : constant N.Element_Count := Tiny_Model.Embedding;
         Soft   : Vocab.Token_Id;
         Rows   : T.Real_Array_Access;
         Places : constant L.Row_Places_Access :=
           new L.Row_Places'
             (0 => (Row => 0, Column => 0, First => True, Last => False, Advance => 2),
              1 => (Row => 0, Column => 1, First => False, Last => False, Advance => 2),
              2 => (Row => 1, Column => 0, First => False, Last => False, Advance => 2),
              3 => (Row => 1, Column => 1, First => False, Last => True, Advance => 2));
         Placed, Unplaced : N.Real_Array
           (0 .. N.Element_Count (Tiny_Model.Vocabulary) - 1);
         use type Model_Runner.Kernels.Rotary_Place;

         procedure Expect
           (Index : Natural; T, H, W : Natural; What : String) is
            Got : constant Model_Runner.Kernels.Rotary_Place :=
              L.Turned_By (Live, Index);
         begin
            Assert (Got = (T => T, H => H, W => W),
                    What & ": position" & Natural'Image (Index) & " turns by"
                    & Natural'Image (Got.T) & Natural'Image (Got.H)
                    & Natural'Image (Got.W) & ", not"
                    & Natural'Image (T) & Natural'Image (H) & Natural'Image (W));
         end Expect;
      begin
         Model_Runner.GGUF.Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");
         L.Prepare (Ready, Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not prepare: "
                 & E.Error_Code'Image (Status.Code));
         Assert (L.Config (Ready).Sections.T = 1
                 and then L.Config (Ready).Sections.H = 1
                 and then L.Config (Ready).Sections.Interleaved,
                 "the sections were not read");
         Words := L.Vocabulary (Ready);
         Soft := Vocab.Find (Words.all, "<0x64>");

         T.Allocate (4 * Width, Rows);
         Seed := 2424;
         for Value of Rows.all loop
            Value := Next;
         end loop;

         declare
            Tokens : constant Vocab.Token_Array :=
              [Vocab.Beginning_Token (Words.all), Soft, Soft, Soft, Soft,
               Vocab.Find (Words.all, "a"), Vocab.Find (Words.all, "b")];
         begin
            L.Open (Live, Ready, 32, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");

            --  A hybrid rewinds only as far as it kept its states.
            L.Keep_States (Live, 4, Status);
            Assert (E.Is_Ok (Status), "the states were not kept");

            L.Evaluate_Batch
              (Live, Ready, Tokens, Placed,
               Given => (Token => Soft, Rows => Rows, First => 0,
                         Places => Places, Causal => True, others => <>),
               Status => Status);
            Assert (E.Is_Ok (Status), "the placed batch failed: "
                    & E.Error_Code'Image (Status.Code));

            --  The beginning at 0; the picture from 1: its rows at
            --  (1, 1 + row, 1 + column); the text after at 1 + 2 = 3, 4.
            Expect (0, 0, 0, 0, "placed");
            Expect (1, 1, 1, 1, "placed");
            Expect (2, 1, 1, 2, "placed");
            Expect (3, 1, 2, 1, "placed");
            Expect (4, 1, 2, 2, "placed");
            Expect (5, 3, 3, 3, "placed");
            Expect (6, 4, 4, 4, "placed");

            --  A token more, one at a time: five.
            L.Evaluate (Live, Ready, Vocab.Find (Words.all, "c"), Unplaced,
                        Status => Status);
            Assert (E.Is_Ok (Status), "the token after the batch failed");
            Expect (7, 5, 5, 5, "placed, one more");

            --  Snapshotted and adopted into another session, the places
            --  come back with the context, and the next token goes on
            --  from them; a snapshot without them -- cut short of the
            --  marks -- adopts with every position at its index, which is
            --  what one from before they were written held.
            declare
               Bytes : B.Byte_Array_Access;
               Twin  : L.Session;
            begin
               L.Snapshot (Live, Ready, Bytes, Status);
               Assert (E.Is_Ok (Status) and then Bytes /= null,
                       "the snapshot failed");
               L.Open (Twin, Ready, 32, Status => Status);
               Assert (E.Is_Ok (Status), "the twin did not open");
               L.Adopt (Twin, Ready, Bytes.all, Status);
               Assert (E.Is_Ok (Status), "the twin did not adopt: "
                       & E.Error_Code'Image (Status.Code));
               Assert (L.Turned_By (Twin, 4) = (T => 1, H => 2, W => 2)
                       and then L.Turned_By (Twin, 7) = (T => 5, H => 5, W => 5),
                       "the adopted places are not the snapshotted ones");
               L.Evaluate (Twin, Ready, Vocab.Find (Words.all, "b"), Unplaced,
                           Status => Status);
               Assert (E.Is_Ok (Status), "the twin did not evaluate");
               Assert (L.Turned_By (Twin, 8) = (T => 6, H => 6, W => 6),
                       "the twin did not go on from the adopted places");

               L.Reset (Twin);
               L.Adopt (Twin, Ready, Bytes (Bytes'First .. Bytes'Last - 8 * 4 * 8),
                        Status);
               Assert (E.Is_Ok (Status), "the cut snapshot did not adopt");
               Assert (L.Turned_By (Twin, 4) = (T => 4, H => 4, W => 4),
                       "a snapshot without marks did not turn by the index");
               L.Close (Twin);
               B.Free (Bytes);
            end;

            --  Rewound to the text after the picture and given it again:
            --  the same places.
            L.Rewind (Live, 5, Status);
            Assert (E.Is_Ok (Status), "the rewind failed");
            L.Evaluate (Live, Ready, Vocab.Find (Words.all, "a"), Unplaced,
                        Status => Status);
            Assert (E.Is_Ok (Status), "the token after the rewind failed");
            Expect (5, 3, 3, 3, "rewound");

            --  The same batch with no places: every position its index,
            --  and the logits at the end another answer.
            L.Reset (Live);
            L.Evaluate_Batch
              (Live, Ready, Tokens, Unplaced,
               Given => (Token => Soft, Rows => Rows, First => 0,
                         Places => null, Causal => True, others => <>),
               Status => Status);
            Assert (E.Is_Ok (Status), "the unplaced batch failed");
            Expect (4, 4, 4, 4, "unplaced");
            Expect (6, 6, 6, 6, "unplaced");
            declare
               Same : Boolean := True;
            begin
               for Index in Placed'Range loop
                  Same := Same and then Placed (Index) = Unplaced (Index);
               end loop;
               Assert (not Same, "the places changed no logit");
            end;

            L.Close (Live);
         end;

         T.Free (Rows);
         L.Close (Ready, Status);
         Model_Runner.GGUF.Containers.Close (Parsed);
      end;

      B.Free (Image);
   end Placed_Rows_Turn_By_Row_And_Column;

   ----------------------------------------
   -- A_Pictures_Rows_See_Each_Other --
   ----------------------------------------

   --  The rows a picture stands behind attend to each other both ways:
   --  the state at the first of them depends on the second, which a
   --  causal position's would not, and a text position after the run
   --  is causal still. Two batches differing only in the second row are
   --  evaluated with every position's state written out.
   procedure A_Pictures_Rows_See_Each_Other
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed : Model_Runner.GGUF.Containers.Container;
         Ready  : L.Model;
         Live   : L.Session;
         Status : E.Error_Info;
         Words  : access constant Vocab.Vocabulary;
         Width  : constant N.Element_Count := Tiny_Model.Embedding;
         Soft   : Vocab.Token_Id;
         Rows_A, Rows_B : T.Real_Array_Access;
         States_A, States_B, States_C : T.Real_Array_Access;
         Logits : N.Real_Array (0 .. N.Element_Count (Tiny_Model.Vocabulary) - 1);

         --  Whether two states at a position differ.
         function Differ
           (X, Y : T.Real_Array_Access; At_Position : N.Element_Count)
            return Boolean is
         begin
            for D in 0 .. Width - 1 loop
               if X (At_Position * Width + D) /= Y (At_Position * Width + D) then
                  return True;
               end if;
            end loop;
            return False;
         end Differ;
      begin
         Model_Runner.GGUF.Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the tiny model did not parse");
         L.Prepare (Ready, Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the tiny model did not prepare");
         Words := L.Vocabulary (Ready);
         Soft := Vocab.Find (Words.all, "<0x64>");

         --  Two rows of given values, the second of them different
         --  between the two sets.
         T.Allocate (2 * Width, Rows_A);
         T.Allocate (2 * Width, Rows_B);
         Seed := 4242;
         for Value of Rows_A.all loop
            Value := Next;
         end loop;
         Rows_B.all := Rows_A.all;
         for D in Width .. 2 * Width - 1 loop
            Rows_B (D) := Rows_B (D) + 0.5;
         end loop;
         T.Allocate (4 * Width, States_A);
         T.Allocate (4 * Width, States_B);
         T.Allocate (4 * Width, States_C);

         declare
            Tokens : constant Vocab.Token_Array :=
              [Vocab.Beginning_Token (Words.all), Soft, Soft,
               Vocab.Find (Words.all, "a")];
         begin
            L.Open (Live, Ready, 16, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");
            L.Evaluate_Batch
              (Live, Ready, Tokens, Logits, States => States_A,
               Given => (Token => Soft, Rows => Rows_A, First => 0, others => <>),
               Status => Status);
            Assert (E.Is_Ok (Status), "the first batch failed: "
                    & E.Error_Code'Image (Status.Code));
            L.Reset (Live);
            L.Evaluate_Batch
              (Live, Ready, Tokens, Logits, States => States_B,
               Given => (Token => Soft, Rows => Rows_B, First => 0, others => <>),
               Status => Status);
            Assert (E.Is_Ok (Status), "the second batch failed: "
                    & E.Error_Code'Image (Status.Code));

            Assert (not Differ (States_A, States_B, 0),
                    "the beginning's state changed with a row after it");
            Assert (Differ (States_A, States_B, 1),
                    "the first row's state did not see the second row");
            Assert (Differ (States_A, States_B, 2),
                    "the second row's state did not change with the row");

            --  And a batch that ends inside the run, then the rest: the
            --  first row cannot see a second that has not arrived, so its
            --  state is the causal one -- which is what the generator's
            --  batch boundaries are moved to avoid.
            L.Reset (Live);
            L.Evaluate_Batch
              (Live, Ready, Tokens (1 .. 2), Logits, States => States_C,
               Given => (Token => Soft, Rows => Rows_B, First => 0, others => <>),
               Status => Status);
            Assert (E.Is_Ok (Status), "the split batch failed");
            Assert (Differ (States_B, States_C, 1),
                    "a row cut off from the run's end saw a row not yet "
                    & "evaluated");
            L.Close (Live);
         end;

         T.Free (Rows_A);
         T.Free (Rows_B);
         T.Free (States_A);
         T.Free (States_B);
         T.Free (States_C);
         L.Close (Ready, Status);
         Model_Runner.GGUF.Containers.Close (Parsed);
      end;

      B.Free (Image);
   end A_Pictures_Rows_See_Each_Other;

   -----------------------------------------------------
   -- The_Minicpm_Projector_Encodes_As_The_Reference --
   -----------------------------------------------------

   --  The MiniCPM-V resampler's shape, written small: two-pixel patches
   --  over an eight-pixel square -- sixteen patches -- through a SigLIP
   --  encoder of two blocks; then a resampler of four learned query rows
   --  over a text width of a hundred and twenty-eight, one head of that
   --  width. The learned position bank has seventy a side, as the SigLIP
   --  bucket scheme selects, whatever the patch grid.
   Patch_M  : constant := 4;
   Size_M   : constant := 16;
   Width_M  : constant := 8;
   Heads_M  : constant := 2;
   Head_M   : constant := Width_M / Heads_M;
   Feed_M   : constant := 16;
   Blocks_M : constant := 2;
   Elements_M : constant := 3 * Patch_M * Patch_M;
   Bank_M   : constant := 70 * 70;

   P_M      : constant := 128;
   Nq_M     : constant := 4;
   DHead_M  : constant := 128;
   NHead_M  : constant := P_M / DHead_M;
   Quarter_M : constant := P_M / 4;
   Half_M   : constant := P_M / 2;

   type Minicpm_Block is record
      Ln1_W, Ln1_B, Ln2_W, Ln2_B : N.Real_Array (0 .. Width_M - 1);
      Q, K, V, O : N.Real_Array (0 .. Width_M * Width_M - 1);
      Q_B, K_B, V_B, O_B : N.Real_Array (0 .. Width_M - 1);
      Up   : N.Real_Array (0 .. Feed_M * Width_M - 1);
      Up_B : N.Real_Array (0 .. Feed_M - 1);
      Down : N.Real_Array (0 .. Width_M * Feed_M - 1);
      Down_B : N.Real_Array (0 .. Width_M - 1);
   end record;

   type Minicpm_Block_List is array (0 .. Blocks_M - 1) of Minicpm_Block;

   type Minicpm_Weights is record
      Patch  : N.Real_Array (0 .. Width_M * Elements_M - 1);
      Patch_B : N.Real_Array (0 .. Width_M - 1);
      Pos    : N.Real_Array (0 .. Bank_M * Width_M - 1);
      Blocks : Minicpm_Block_List;
      Post_W, Post_B : N.Real_Array (0 .. Width_M - 1);
      Query  : N.Real_Array (0 .. Nq_M * P_M - 1);
      Kv_Proj : N.Real_Array (0 .. P_M * Width_M - 1);
      Attn_Q, Attn_K, Attn_V, Attn_O : N.Real_Array (0 .. P_M * P_M - 1);
      Attn_Q_B, Attn_K_B, Attn_V_B, Attn_O_B : N.Real_Array (0 .. P_M - 1);
      Ln_Q_W, Ln_Q_B, Ln_Kv_W, Ln_Kv_B, Ln_Post_W, Ln_Post_B :
        N.Real_Array (0 .. P_M - 1);
      Proj   : N.Real_Array (0 .. P_M * P_M - 1);
   end record;

   type Minicpm_Weights_Access is access Minicpm_Weights;

   procedure Free is new Ada.Unchecked_Deallocation
     (Minicpm_Weights, Minicpm_Weights_Access);

   --  A vector of ones plus a small jitter, for a norm gain.
   function Gain_Row (Length : N.Element_Count) return N.Real_Array is
      Result : N.Real_Array := Random_Row (Length, 0.3);
   begin
      for Value of Result loop
         Value := Value + 1.0;
      end loop;
      return Result;
   end Gain_Row;

   function Fresh_Minicpm_Weights return Minicpm_Weights_Access is
      W : constant Minicpm_Weights_Access := new Minicpm_Weights;
   begin
      Seed := 24680;
      W.Patch := Random_Row (Width_M * Elements_M, 0.05);
      W.Patch_B := Random_Row (Width_M, 0.1);
      W.Pos := Random_Row (Bank_M * Width_M, 0.3);
      for Index in W.Blocks'Range loop
         W.Blocks (Index).Ln1_W := Gain_Row (Width_M);
         W.Blocks (Index).Ln1_B := Random_Row (Width_M, 0.1);
         W.Blocks (Index).Ln2_W := Gain_Row (Width_M);
         W.Blocks (Index).Ln2_B := Random_Row (Width_M, 0.1);
         W.Blocks (Index).Q := Random_Row (Width_M * Width_M, 0.3);
         W.Blocks (Index).K := Random_Row (Width_M * Width_M, 0.3);
         W.Blocks (Index).V := Random_Row (Width_M * Width_M, 0.3);
         W.Blocks (Index).O := Random_Row (Width_M * Width_M, 0.3);
         W.Blocks (Index).Q_B := Random_Row (Width_M, 0.1);
         W.Blocks (Index).K_B := Random_Row (Width_M, 0.1);
         W.Blocks (Index).V_B := Random_Row (Width_M, 0.1);
         W.Blocks (Index).O_B := Random_Row (Width_M, 0.1);
         W.Blocks (Index).Up := Random_Row (Feed_M * Width_M, 0.3);
         W.Blocks (Index).Up_B := Random_Row (Feed_M, 0.1);
         W.Blocks (Index).Down := Random_Row (Width_M * Feed_M, 0.2);
         W.Blocks (Index).Down_B := Random_Row (Width_M, 0.1);
      end loop;
      W.Post_W := Gain_Row (Width_M);
      W.Post_B := Random_Row (Width_M, 0.1);
      W.Query := Random_Row (Nq_M * P_M, 0.3);
      W.Kv_Proj := Random_Row (P_M * Width_M, 0.1);
      W.Attn_Q := Random_Row (P_M * P_M, 0.05);
      W.Attn_K := Random_Row (P_M * P_M, 0.05);
      W.Attn_V := Random_Row (P_M * P_M, 0.05);
      W.Attn_O := Random_Row (P_M * P_M, 0.05);
      W.Attn_Q_B := Random_Row (P_M, 0.1);
      W.Attn_K_B := Random_Row (P_M, 0.1);
      W.Attn_V_B := Random_Row (P_M, 0.1);
      W.Attn_O_B := Random_Row (P_M, 0.1);
      W.Ln_Q_W := Gain_Row (P_M);
      W.Ln_Q_B := Random_Row (P_M, 0.1);
      W.Ln_Kv_W := Gain_Row (P_M);
      W.Ln_Kv_B := Random_Row (P_M, 0.1);
      W.Ln_Post_W := Gain_Row (P_M);
      W.Ln_Post_B := Random_Row (P_M, 0.1);
      W.Proj := Random_Row (P_M * P_M, 0.05);
      return W;
   end Fresh_Minicpm_Weights;

   procedure Write_Minicpm_Projector
     (Path : String; W : Minicpm_Weights; Kind : String := "resampler";
      Swapped : Boolean := False; Version : Natural := 3)
   is
      Builder : Fixtures.Builder;
      File    : B.Byte_Array_Access;
      use Ada.Streams.Stream_IO;
      Handle  : File_Type;

      procedure Tensor
        (Name : String; Dims : Fixtures.Dimension_List; Values : N.Real_Array) is
      begin
         Fixtures.Add_Tensor
           (Builder, Name, Dims, G.Type_F32, Fixtures.Encode_F32 (Values));
      end Tensor;
   begin
      Fixtures.Reset (Builder);
      Fixtures.Add_String (Builder, "general.architecture", "clip");
      Fixtures.Add_String (Builder, "clip.projector_type", Kind);
      Fixtures.Add_U32 (Builder, "clip.vision.image_size", Size_M);
      Fixtures.Add_U32 (Builder, "clip.vision.patch_size", Patch_M);
      Fixtures.Add_U32 (Builder, "clip.vision.embedding_length", Width_M);
      Fixtures.Add_U32 (Builder, "clip.vision.feed_forward_length", Feed_M);
      Fixtures.Add_U32 (Builder, "clip.vision.projection_dim", P_M);
      Fixtures.Add_U32 (Builder, "clip.vision.block_count", Blocks_M);
      Fixtures.Add_U32 (Builder, "clip.vision.attention.head_count", Heads_M);
      Fixtures.Add_U32 (Builder, "clip.minicpmv_query_num", Nq_M);
      Fixtures.Add_U32
        (Builder, "clip.minicpmv_version", Interfaces.Unsigned_32 (Version));
      Fixtures.Add_F32
        (Builder, "clip.vision.attention.layer_norm_epsilon", 1.0e-6);
      Fixtures.Begin_Array
        (Builder, "clip.vision.image_mean", G.Value_Float32, 3);
      for Channel in 1 .. 3 loop
         Fixtures.Float_Element (Builder, 0.5);
      end loop;
      Fixtures.End_Array (Builder);
      Fixtures.Begin_Array
        (Builder, "clip.vision.image_std", G.Value_Float32, 3);
      for Channel in 1 .. 3 loop
         Fixtures.Float_Element (Builder, 0.5);
      end loop;
      Fixtures.End_Array (Builder);

      Tensor ("v.patch_embd.weight", [Patch_M, Patch_M, 3, Width_M], W.Patch);
      Tensor ("v.patch_embd.bias", [Width_M], W.Patch_B);
      Tensor ("v.position_embd.weight", [Width_M, Bank_M], W.Pos);
      for Index in W.Blocks'Range loop
         declare
            Prefix : constant String :=
              "v.blk." & Model_Runner.Text.Image (Long_Long_Integer (Index)) & ".";
            Current : Minicpm_Block renames W.Blocks (Index);
         begin
            Tensor (Prefix & "ln1.weight", [Width_M], Current.Ln1_W);
            Tensor (Prefix & "ln1.bias", [Width_M], Current.Ln1_B);
            Tensor (Prefix & "ln2.weight", [Width_M], Current.Ln2_W);
            Tensor (Prefix & "ln2.bias", [Width_M], Current.Ln2_B);
            Tensor (Prefix & "attn_q.weight", [Width_M, Width_M], Current.Q);
            Tensor (Prefix & "attn_q.bias", [Width_M], Current.Q_B);
            Tensor (Prefix & "attn_k.weight", [Width_M, Width_M], Current.K);
            Tensor (Prefix & "attn_k.bias", [Width_M], Current.K_B);
            Tensor (Prefix & "attn_v.weight", [Width_M, Width_M], Current.V);
            Tensor (Prefix & "attn_v.bias", [Width_M], Current.V_B);
            Tensor (Prefix & "attn_out.weight", [Width_M, Width_M], Current.O);
            Tensor (Prefix & "attn_out.bias", [Width_M], Current.O_B);
            --  The widening half is named "ffn_up" here, but a real
            --  MiniCPM-V file names it "ffn_down"; Swapped writes it that
            --  way to exercise Bind's shape-told naming.
            declare
               Widen  : constant String :=
                 (if Swapped then "ffn_down" else "ffn_up");
               Narrow : constant String :=
                 (if Swapped then "ffn_up" else "ffn_down");
            begin
               Tensor (Prefix & Widen & ".weight", [Width_M, Feed_M], Current.Up);
               Tensor (Prefix & Widen & ".bias", [Feed_M], Current.Up_B);
               Tensor (Prefix & Narrow & ".weight", [Feed_M, Width_M],
                       Current.Down);
               Tensor (Prefix & Narrow & ".bias", [Width_M], Current.Down_B);
            end;
         end;
      end loop;
      Tensor ("v.post_ln.weight", [Width_M], W.Post_W);
      Tensor ("v.post_ln.bias", [Width_M], W.Post_B);

      Tensor ("resampler.query", [P_M, Nq_M], W.Query);
      Tensor ("resampler.kv.weight", [Width_M, P_M], W.Kv_Proj);
      Tensor ("resampler.attn.q.weight", [P_M, P_M], W.Attn_Q);
      Tensor ("resampler.attn.q.bias", [P_M], W.Attn_Q_B);
      Tensor ("resampler.attn.k.weight", [P_M, P_M], W.Attn_K);
      Tensor ("resampler.attn.k.bias", [P_M], W.Attn_K_B);
      Tensor ("resampler.attn.v.weight", [P_M, P_M], W.Attn_V);
      Tensor ("resampler.attn.v.bias", [P_M], W.Attn_V_B);
      Tensor ("resampler.attn.out.weight", [P_M, P_M], W.Attn_O);
      Tensor ("resampler.attn.out.bias", [P_M], W.Attn_O_B);
      Tensor ("resampler.ln_q.weight", [P_M], W.Ln_Q_W);
      Tensor ("resampler.ln_q.bias", [P_M], W.Ln_Q_B);
      Tensor ("resampler.ln_kv.weight", [P_M], W.Ln_Kv_W);
      Tensor ("resampler.ln_kv.bias", [P_M], W.Ln_Kv_B);
      Tensor ("resampler.ln_post.weight", [P_M], W.Ln_Post_W);
      Tensor ("resampler.ln_post.bias", [P_M], W.Ln_Post_B);
      Tensor ("resampler.proj.weight", [P_M, P_M], W.Proj);

      Fixtures.Build (Builder, File);
      Create (Handle, Out_File, Path);
      declare
         Block : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (File.all'Length))
           with Import, Address => File.all'Address;
      begin
         Write (Handle, Block);
      end;
      Close (Handle);
      B.Free (File);
   end Write_Minicpm_Projector;

   --  The rows the small resampler should make of a picture, in binary64:
   --  the SigLIP encoder placed by the bucketed bank, then the resampler
   --  -- the states lifted to the text width and normed, the queries
   --  normed, the sinusoidal place, the cross-attention, the output norm
   --  and the projection.
   procedure Minicpm_Reference_Rows
     (W : Minicpm_Weights; Picture : Images.Raster;
      Rows : out N.Wide_Real_Array)
   is
      subtype WR is N.Wide_Real;
      --  MiniCPM-V keeps the picture's aspect: the grid is its own sides
      --  in whole patches, and it is resampled to exactly that.
      Cols    : constant Natural := Natural'Max (1, Picture.Width / Patch_M);
      Rows_P  : constant Natural := Natural'Max (1, Picture.Height / Patch_M);
      Target_W : constant Natural := Cols * Patch_M;
      Target_H : constant Natural := Rows_P * Patch_M;
      Patches : constant Natural := Cols * Rows_P;
      type ViT_Mat is array (0 .. Patches - 1, 0 .. Width_M - 1) of WR;
      type State_Mat is array (0 .. Patches - 1, 0 .. P_M - 1) of WR;
      type Query_Mat is array (0 .. Nq_M - 1, 0 .. P_M - 1) of WR;
      X, H, Q, K, V, A : ViT_Mat;
      F : array (0 .. Patches - 1, 0 .. Feed_M - 1) of WR;
      Vkv, Vkvn, Pos, Kk, Kmat, Vmat : State_Mat;
      Qsrc, Qn, Qmat, Att, Rout, Routn : Query_Mat;
      Omega : array (0 .. Quarter_M - 1) of WR;
      Pixels : Images.Raster;
      Eps : constant WR := 1.0e-6;

      function GELU (Value : WR) return WR
      is (0.5 * Value
          * (1.0 + Wide_Math.Tanh
                     (0.797_884_560_802_865_4
                      * (Value + 0.044_715 * Value * Value * Value))));

      procedure Layer_Norm_V
        (Source : ViT_Mat; Gain, Bias : N.Real_Array; Target : out ViT_Mat) is
      begin
         for P in 0 .. Patches - 1 loop
            declare
               Mean, Variance : WR := 0.0;
            begin
               for D in 0 .. Width_M - 1 loop
                  Mean := Mean + Source (P, D);
               end loop;
               Mean := Mean / WR (Width_M);
               for D in 0 .. Width_M - 1 loop
                  Variance := Variance + (Source (P, D) - Mean) ** 2;
               end loop;
               Variance := Variance / WR (Width_M);
               for D in 0 .. Width_M - 1 loop
                  Target (P, D) :=
                    (Source (P, D) - Mean) / Wide_Math.Sqrt (Variance + Eps)
                    * WR (Gain (N.Element_Count (D)))
                    + WR (Bias (N.Element_Count (D)));
               end loop;
            end;
         end loop;
      end Layer_Norm_V;

      procedure Project_V
        (Source : ViT_Mat; Weight, Bias : N.Real_Array; Target : out ViT_Mat) is
      begin
         for P in 0 .. Patches - 1 loop
            for R in 0 .. Width_M - 1 loop
               declare
                  Sum : WR := WR (Bias (N.Element_Count (R)));
               begin
                  for C in 0 .. Width_M - 1 loop
                     Sum := Sum + Source (P, C)
                       * WR (Weight (N.Element_Count (R * Width_M + C)));
                  end loop;
                  Target (P, R) := Sum;
               end;
            end loop;
         end loop;
      end Project_V;
   begin
      Images.Resample (Picture, Target_W, Target_H, Pixels);

      --  Patches, embedded and placed by the learned bank the grid
      --  buckets into.
      for PY in 0 .. Rows_P - 1 loop
         for PX in 0 .. Cols - 1 loop
            declare
               P : constant Natural := PY * Cols + PX;
               Bucket : constant Natural :=
                 (70 * PY / Rows_P) * 70 + (70 * PX / Cols);
            begin
               for R in 0 .. Width_M - 1 loop
                  declare
                     Sum : WR := WR (W.Patch_B (N.Element_Count (R)))
                       + WR (W.Pos (N.Element_Count (Bucket * Width_M + R)));
                  begin
                     for C in 0 .. 2 loop
                        for KY in 0 .. Patch_M - 1 loop
                           for KX in 0 .. Patch_M - 1 loop
                              declare
                                 Value : constant WR :=
                                   (WR (Pixel (Pixels, PX * Patch_M + KX,
                                               PY * Patch_M + KY, C)) / 255.0
                                    - 0.5) / 0.5;
                                 Index : constant Natural :=
                                   C * Patch_M * Patch_M + KY * Patch_M + KX;
                              begin
                                 Sum := Sum + Value
                                   * WR (W.Patch (N.Element_Count
                                                    (R * Elements_M + Index)));
                              end;
                           end loop;
                        end loop;
                     end loop;
                     X (P, R) := Sum;
                  end;
               end loop;
            end;
         end loop;
      end loop;
      Images.Free (Pixels);

      for Index in W.Blocks'Range loop
         declare
            Current : Minicpm_Block renames W.Blocks (Index);
         begin
            Layer_Norm_V (X, Current.Ln1_W, Current.Ln1_B, H);
            Project_V (H, Current.Q, Current.Q_B, Q);
            Project_V (H, Current.K, Current.K_B, K);
            Project_V (H, Current.V, Current.V_B, V);
            for Hd in 0 .. Heads_M - 1 loop
               for P in 0 .. Patches - 1 loop
                  declare
                     Scores : array (0 .. Patches - 1) of WR;
                     Largest, Total : WR;
                  begin
                     for O in 0 .. Patches - 1 loop
                        Scores (O) := 0.0;
                        for D in 0 .. Head_M - 1 loop
                           Scores (O) := Scores (O)
                             + Q (P, Hd * Head_M + D) * K (O, Hd * Head_M + D);
                        end loop;
                        Scores (O) := Scores (O) / Wide_Math.Sqrt (WR (Head_M));
                     end loop;
                     Largest := Scores (0);
                     for O in 1 .. Patches - 1 loop
                        Largest := WR'Max (Largest, Scores (O));
                     end loop;
                     Total := 0.0;
                     for O in 0 .. Patches - 1 loop
                        Scores (O) := Wide_Math.Exp (Scores (O) - Largest);
                        Total := Total + Scores (O);
                     end loop;
                     for D in 0 .. Head_M - 1 loop
                        declare
                           Sum : WR := 0.0;
                        begin
                           for O in 0 .. Patches - 1 loop
                              Sum := Sum
                                + Scores (O) / Total * V (O, Hd * Head_M + D);
                           end loop;
                           A (P, Hd * Head_M + D) := Sum;
                        end;
                     end loop;
                  end;
               end loop;
            end loop;
            Project_V (A, Current.O, Current.O_B, H);
            for P in 0 .. Patches - 1 loop
               for D in 0 .. Width_M - 1 loop
                  X (P, D) := X (P, D) + H (P, D);
               end loop;
            end loop;

            Layer_Norm_V (X, Current.Ln2_W, Current.Ln2_B, H);
            for P in 0 .. Patches - 1 loop
               for R in 0 .. Feed_M - 1 loop
                  declare
                     Sum : WR := WR (Current.Up_B (N.Element_Count (R)));
                  begin
                     for C in 0 .. Width_M - 1 loop
                        Sum := Sum + H (P, C)
                          * WR (Current.Up (N.Element_Count (R * Width_M + C)));
                     end loop;
                     F (P, R) := GELU (Sum);
                  end;
               end loop;
               for R in 0 .. Width_M - 1 loop
                  declare
                     Sum : WR := WR (Current.Down_B (N.Element_Count (R)));
                  begin
                     for C in 0 .. Feed_M - 1 loop
                        Sum := Sum + F (P, C)
                          * WR (Current.Down (N.Element_Count (R * Feed_M + C)));
                     end loop;
                     X (P, R) := X (P, R) + Sum;
                  end;
               end loop;
            end loop;
         end;
      end loop;

      Layer_Norm_V (X, W.Post_W, W.Post_B, H);

      --  The resampler. The states to the text width and normed.
      for P in 0 .. Patches - 1 loop
         for R in 0 .. P_M - 1 loop
            declare
               Sum : WR := 0.0;
            begin
               for C in 0 .. Width_M - 1 loop
                  Sum := Sum + H (P, C)
                    * WR (W.Kv_Proj (N.Element_Count (R * Width_M + C)));
               end loop;
               Vkv (P, R) := Sum;
            end;
         end loop;
      end loop;
      for P in 0 .. Patches - 1 loop
         declare
            Mean, Variance : WR := 0.0;
         begin
            for D in 0 .. P_M - 1 loop
               Mean := Mean + Vkv (P, D);
            end loop;
            Mean := Mean / WR (P_M);
            for D in 0 .. P_M - 1 loop
               Variance := Variance + (Vkv (P, D) - Mean) ** 2;
            end loop;
            Variance := Variance / WR (P_M);
            for D in 0 .. P_M - 1 loop
               Vkvn (P, D) :=
                 (Vkv (P, D) - Mean) / Wide_Math.Sqrt (Variance + Eps)
                 * WR (W.Ln_Kv_W (N.Element_Count (D)))
                 + WR (W.Ln_Kv_B (N.Element_Count (D)));
            end loop;
         end;
      end loop;

      --  The learned queries normed.
      for I in 0 .. Nq_M - 1 loop
         for D in 0 .. P_M - 1 loop
            Qsrc (I, D) := WR (W.Query (N.Element_Count (I * P_M + D)));
         end loop;
      end loop;
      for I in 0 .. Nq_M - 1 loop
         declare
            Mean, Variance : WR := 0.0;
         begin
            for D in 0 .. P_M - 1 loop
               Mean := Mean + Qsrc (I, D);
            end loop;
            Mean := Mean / WR (P_M);
            for D in 0 .. P_M - 1 loop
               Variance := Variance + (Qsrc (I, D) - Mean) ** 2;
            end loop;
            Variance := Variance / WR (P_M);
            for D in 0 .. P_M - 1 loop
               Qn (I, D) :=
                 (Qsrc (I, D) - Mean) / Wide_Math.Sqrt (Variance + Eps)
                 * WR (W.Ln_Q_W (N.Element_Count (D)))
                 + WR (W.Ln_Q_B (N.Element_Count (D)));
            end loop;
         end;
      end loop;

      --  The sinusoidal place, and the keys as the states plus it.
      for I in 0 .. Quarter_M - 1 loop
         Omega (I) := 1.0 / Wide_Math."**" (10_000.0, WR (I) / WR (Quarter_M));
      end loop;
      for P in 0 .. Patches - 1 loop
         declare
            Rowv : constant WR := WR (P / Cols);
            Colv : constant WR := WR (P mod Cols);
         begin
            for I in 0 .. Quarter_M - 1 loop
               Pos (P, I) := Wide_Math.Sin (Omega (I) * Colv);
               Pos (P, Quarter_M + I) := Wide_Math.Cos (Omega (I) * Colv);
               Pos (P, Half_M + I) := Wide_Math.Sin (Omega (I) * Rowv);
               Pos (P, Half_M + Quarter_M + I) := Wide_Math.Cos (Omega (I) * Rowv);
            end loop;
            for D in 0 .. P_M - 1 loop
               Kk (P, D) := Vkvn (P, D) + Pos (P, D);
            end loop;
         end;
      end loop;

      --  Query, key and value each through their weights.
      for I in 0 .. Nq_M - 1 loop
         for R in 0 .. P_M - 1 loop
            declare
               Sum : WR := WR (W.Attn_Q_B (N.Element_Count (R)));
            begin
               for C in 0 .. P_M - 1 loop
                  Sum := Sum + Qn (I, C)
                    * WR (W.Attn_Q (N.Element_Count (R * P_M + C)));
               end loop;
               Qmat (I, R) := Sum;
            end;
         end loop;
      end loop;
      for P in 0 .. Patches - 1 loop
         for R in 0 .. P_M - 1 loop
            declare
               Sk : WR := WR (W.Attn_K_B (N.Element_Count (R)));
               Sv : WR := WR (W.Attn_V_B (N.Element_Count (R)));
            begin
               for C in 0 .. P_M - 1 loop
                  Sk := Sk + Kk (P, C)
                    * WR (W.Attn_K (N.Element_Count (R * P_M + C)));
                  Sv := Sv + Vkvn (P, C)
                    * WR (W.Attn_V (N.Element_Count (R * P_M + C)));
               end loop;
               Kmat (P, R) := Sk;
               Vmat (P, R) := Sv;
            end;
         end loop;
      end loop;

      --  The cross-attention: each query over every patch, a head of the
      --  whole width, scaled by the root of a hundred and twenty-eight.
      for Hd in 0 .. NHead_M - 1 loop
         for I in 0 .. Nq_M - 1 loop
            declare
               Scores : array (0 .. Patches - 1) of WR;
               Largest, Total : WR;
            begin
               for O in 0 .. Patches - 1 loop
                  Scores (O) := 0.0;
                  for D in 0 .. DHead_M - 1 loop
                     Scores (O) := Scores (O)
                       + Qmat (I, Hd * DHead_M + D) * Kmat (O, Hd * DHead_M + D);
                  end loop;
                  Scores (O) := Scores (O) / Wide_Math.Sqrt (WR (DHead_M));
               end loop;
               Largest := Scores (0);
               for O in 1 .. Patches - 1 loop
                  Largest := WR'Max (Largest, Scores (O));
               end loop;
               Total := 0.0;
               for O in 0 .. Patches - 1 loop
                  Scores (O) := Wide_Math.Exp (Scores (O) - Largest);
                  Total := Total + Scores (O);
               end loop;
               for D in 0 .. DHead_M - 1 loop
                  declare
                     Sum : WR := 0.0;
                  begin
                     for O in 0 .. Patches - 1 loop
                        Sum := Sum
                          + Scores (O) / Total * Vmat (O, Hd * DHead_M + D);
                     end loop;
                     Att (I, Hd * DHead_M + D) := Sum;
                  end;
               end loop;
            end;
         end loop;
      end loop;

      --  The blend through the output weights, normed, and projected.
      for I in 0 .. Nq_M - 1 loop
         for R in 0 .. P_M - 1 loop
            declare
               Sum : WR := WR (W.Attn_O_B (N.Element_Count (R)));
            begin
               for C in 0 .. P_M - 1 loop
                  Sum := Sum + Att (I, C)
                    * WR (W.Attn_O (N.Element_Count (R * P_M + C)));
               end loop;
               Rout (I, R) := Sum;
            end;
         end loop;
      end loop;
      for I in 0 .. Nq_M - 1 loop
         declare
            Mean, Variance : WR := 0.0;
         begin
            for D in 0 .. P_M - 1 loop
               Mean := Mean + Rout (I, D);
            end loop;
            Mean := Mean / WR (P_M);
            for D in 0 .. P_M - 1 loop
               Variance := Variance + (Rout (I, D) - Mean) ** 2;
            end loop;
            Variance := Variance / WR (P_M);
            for D in 0 .. P_M - 1 loop
               Routn (I, D) :=
                 (Rout (I, D) - Mean) / Wide_Math.Sqrt (Variance + Eps)
                 * WR (W.Ln_Post_W (N.Element_Count (D)))
                 + WR (W.Ln_Post_B (N.Element_Count (D)));
            end loop;
         end;
      end loop;
      for I in 0 .. Nq_M - 1 loop
         for J in 0 .. P_M - 1 loop
            declare
               Sum : WR := 0.0;
            begin
               for D in 0 .. P_M - 1 loop
                  Sum := Sum + Routn (I, D)
                    * WR (W.Proj (N.Element_Count (J * P_M + D)));
               end loop;
               Rows (N.Element_Count (I * P_M + J)) := Sum;
            end;
         end loop;
      end loop;
   end Minicpm_Reference_Rows;

   procedure The_Minicpm_Projector_Encodes_As_The_Reference
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      W : Minicpm_Weights_Access := Fresh_Minicpm_Weights;
      Picture : Images.Raster;
      Status  : E.Error_Info;
      Wanted  : N.Wide_Real_Array (0 .. Nq_M * P_M - 1);
      Rows    : T.Real_Array_Access;
      Grid_Rows, Grid_Columns : Natural;
      Eyes    : Vision.Encoder;
   begin
      declare
         Data : B.Byte_Array (1 .. 3 * 20 * 30);
      begin
         for Y in 0 .. 29 loop
            for X in 0 .. 19 loop
               declare
                  At_Pixel : constant B.Byte_Count :=
                    B.Byte_Count (3 * (Y * 20 + X)) + 1;
               begin
                  Data (At_Pixel) := B.Byte (X * 12);
                  Data (At_Pixel + 1) := B.Byte (Y * 8);
                  Data (At_Pixel + 2) :=
                    (if X in 5 .. 12 and then Y in 8 .. 20 then 240 else 30);
               end;
            end loop;
         end loop;
         Images.Decode (Bytes_Of ("P6 20 30 255 ") & Data, "test", Picture,
                        Status);
         Assert (E.Is_Ok (Status), "the test picture was refused");
      end;

      Minicpm_Reference_Rows (W.all, Picture, Wanted);

      --  Encodes to the reference rows however the feed-forward halves
      --  are named -- the fixture's way and a real file's swapped way.
      for Swapped in Boolean loop
         Write_Minicpm_Projector
           ("obj/vision-minicpm.gguf", W.all, Swapped => Swapped);
         Vision.Open (Eyes, "obj/vision-minicpm.gguf", Status);
         Assert (E.Is_Ok (Status), "the small resampler did not open: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Vision.Is_Ready (Eyes)
                 and then Vision.Image_Size (Eyes) = Size_M
                 and then Vision.Fixed_Rows (Eyes)
                 and then not Vision.Placed_Rows (Eyes)
                 and then Vision.Rows_Per_Picture (Eyes) = Nq_M
                 and then Vision.Row_Width (Eyes) = P_M
                 and then Vision.Projector (Eyes) = "resampler"
                 and then Vision.Minicpm_Version (Eyes) = 3,
                 "the small resampler's shape was misread");

         Vision.Encode (Eyes, Picture, null, Rows, Grid_Rows, Grid_Columns,
                        Status => Status);
         Assert (E.Is_Ok (Status), "the small resampler did not encode: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Rows /= null and then Rows.all'Length = Nq_M * P_M,
                 "the resampler made the wrong number of rows");
         for J in 0 .. N.Element_Count (Nq_M * P_M - 1) loop
            Assert (abs (N.Wide_Real (Rows (J)) - Wanted (J))
                    <= 1.0e-4 * (1.0 + abs Wanted (J)),
                    "row element" & N.Element_Count'Image (J) & " is "
                    & N.Real'Image (Rows (J)) & " where the reference has "
                    & N.Wide_Real'Image (Wanted (J))
                    & (if Swapped then " with the halves swapped" else ""));
         end loop;
         T.Free (Rows);
         if not Swapped then
            Vision.Close (Eyes);
         end if;
      end loop;

      --  The llava-uhd slicing: a picture within the side is the overview
      --  alone, upscaled to fill it; a larger one is a grid of slices over
      --  a refined whole. Checked against a faithful port of the reference
      --  geometry (image side sixteen, patch four).
      declare
         use type Vision.Slice_Box;
         OW, OH : Positive;
         RW, RH, GC, GR, Count : Natural;
         Sl : Vision.Slice_List;
      begin
         Vision.Plan_Slices (Eyes, 12, 10, OW, OH, RW, RH, GC, GR, Sl, Count);
         Assert (OW = 16 and then OH = 16 and then Count = 0
                 and then GC = 0 and then GR = 0,
                 "a small picture was sliced");

         Vision.Plan_Slices (Eyes, 40, 24, OW, OH, RW, RH, GC, GR, Sl, Count);
         Assert (OW = 20 and then OH = 12
                 and then GC = 2 and then GR = 2 and then Count = 4
                 and then RW = 40 and then RH = 24
                 and then Sl (1) = (0, 0, 20, 12)
                 and then Sl (2) = (20, 0, 20, 12)
                 and then Sl (3) = (0, 12, 20, 12)
                 and then Sl (4) = (20, 12, 20, 12),
                 "a wide picture was sliced wrong");

         Vision.Plan_Slices (Eyes, 24, 40, OW, OH, RW, RH, GC, GR, Sl, Count);
         Assert (OW = 12 and then OH = 20
                 and then GC = 2 and then GR = 2 and then Count = 4
                 and then RW = 24 and then RH = 40
                 and then Sl (1) = (0, 0, 12, 20)
                 and then Sl (4) = (12, 20, 12, 20),
                 "a tall picture was sliced wrong");
      end;
      Vision.Close (Eyes);

      --  A version-2 (2.5) file reads its version back, which is what the
      --  command reads to know the older file frames its slices its own way.
      Write_Minicpm_Projector ("obj/vision-minicpm.gguf", W.all, Version => 2);
      Vision.Open (Eyes, "obj/vision-minicpm.gguf", Status);
      Assert (E.Is_Ok (Status) and then Vision.Minicpm_Version (Eyes) = 2,
              "a version-2 resampler did not read its version");
      Vision.Close (Eyes);

      --  A resampler named as another kind is refused by name.
      Write_Minicpm_Projector ("obj/vision-minicpm.gguf", W.all, Kind => "llava");
      Vision.Open (Eyes, "obj/vision-minicpm.gguf", Status);
      Assert (Status.Code = E.Arch_Unsupported_Projector,
              "a resampler of another kind was not refused by name");
      Assert (not Vision.Is_Ready (Eyes), "a refused resampler reads as ready");

      Images.Free (Picture);
      Free (W);
   end The_Minicpm_Projector_Encodes_As_The_Reference;

   --  MiniCPM-V 4.6's small fixture and its binary64 reference. Sixteen
   --  patches (a four-by-four grid) through the same SigLIP encoder the
   --  resampler runs, then the windowed merger -- a windowed self-attention
   --  after the window layer and a two-by-two downsample -- and, after the
   --  rest of the ViT and a post norm, a final two-by-two merge to one row.
   Insert46 : constant := 0;
   VFeed46  : constant := 24;
   Merged46 : constant := 4 * Width_M;
   Text46   : constant := 4;
   NP2_M    : constant := 1;  --  one row of a four-by-four merged twice

   type Minicpm46_Weights is record
      Patch   : N.Real_Array (0 .. Width_M * Elements_M - 1);
      Patch_B : N.Real_Array (0 .. Width_M - 1);
      Pos     : N.Real_Array (0 .. Bank_M * Width_M - 1);
      Blocks  : Minicpm_Block_List;
      Post_W, Post_B : N.Real_Array (0 .. Width_M - 1);
      VM_Ln1_W, VM_Ln1_B : N.Real_Array (0 .. Width_M - 1);
      VM_Q, VM_K, VM_V, VM_O : N.Real_Array (0 .. Width_M * Width_M - 1);
      VM_Q_B, VM_K_B, VM_V_B, VM_O_B : N.Real_Array (0 .. Width_M - 1);
      VM_Ds_Ln_W, VM_Ds_Ln_B : N.Real_Array (0 .. Merged46 - 1);
      VM_Ds_Up   : N.Real_Array (0 .. VFeed46 * Merged46 - 1);
      VM_Ds_Up_B : N.Real_Array (0 .. VFeed46 - 1);
      VM_Ds_Down : N.Real_Array (0 .. Width_M * VFeed46 - 1);
      VM_Ds_Down_B : N.Real_Array (0 .. Width_M - 1);
      MM_Norm_W, MM_Norm_B : N.Real_Array (0 .. Merged46 - 1);
      MM_Up   : N.Real_Array (0 .. Merged46 * Merged46 - 1);
      MM_Up_B : N.Real_Array (0 .. Merged46 - 1);
      MM_Down : N.Real_Array (0 .. Text46 * Merged46 - 1);
      MM_Down_B : N.Real_Array (0 .. Text46 - 1);
   end record;
   type Minicpm46_Weights_Access is access Minicpm46_Weights;
   procedure Free is new Ada.Unchecked_Deallocation
     (Minicpm46_Weights, Minicpm46_Weights_Access);

   function Fresh_Minicpm46_Weights return Minicpm46_Weights_Access is
      W : constant Minicpm46_Weights_Access := new Minicpm46_Weights;
   begin
      Seed := 13579;
      W.Patch := Random_Row (Width_M * Elements_M, 0.05);
      W.Patch_B := Random_Row (Width_M, 0.1);
      W.Pos := Random_Row (Bank_M * Width_M, 0.3);
      for Index in W.Blocks'Range loop
         W.Blocks (Index).Ln1_W := Gain_Row (Width_M);
         W.Blocks (Index).Ln1_B := Random_Row (Width_M, 0.1);
         W.Blocks (Index).Ln2_W := Gain_Row (Width_M);
         W.Blocks (Index).Ln2_B := Random_Row (Width_M, 0.1);
         W.Blocks (Index).Q := Random_Row (Width_M * Width_M, 0.3);
         W.Blocks (Index).K := Random_Row (Width_M * Width_M, 0.3);
         W.Blocks (Index).V := Random_Row (Width_M * Width_M, 0.3);
         W.Blocks (Index).O := Random_Row (Width_M * Width_M, 0.3);
         W.Blocks (Index).Q_B := Random_Row (Width_M, 0.1);
         W.Blocks (Index).K_B := Random_Row (Width_M, 0.1);
         W.Blocks (Index).V_B := Random_Row (Width_M, 0.1);
         W.Blocks (Index).O_B := Random_Row (Width_M, 0.1);
         W.Blocks (Index).Up := Random_Row (Feed_M * Width_M, 0.3);
         W.Blocks (Index).Up_B := Random_Row (Feed_M, 0.1);
         W.Blocks (Index).Down := Random_Row (Width_M * Feed_M, 0.2);
         W.Blocks (Index).Down_B := Random_Row (Width_M, 0.1);
      end loop;
      W.Post_W := Gain_Row (Width_M);
      W.Post_B := Random_Row (Width_M, 0.1);
      W.VM_Ln1_W := Gain_Row (Width_M);
      W.VM_Ln1_B := Random_Row (Width_M, 0.1);
      W.VM_Q := Random_Row (Width_M * Width_M, 0.3);
      W.VM_K := Random_Row (Width_M * Width_M, 0.3);
      W.VM_V := Random_Row (Width_M * Width_M, 0.3);
      W.VM_O := Random_Row (Width_M * Width_M, 0.3);
      W.VM_Q_B := Random_Row (Width_M, 0.1);
      W.VM_K_B := Random_Row (Width_M, 0.1);
      W.VM_V_B := Random_Row (Width_M, 0.1);
      W.VM_O_B := Random_Row (Width_M, 0.1);
      W.VM_Ds_Ln_W := Gain_Row (Merged46);
      W.VM_Ds_Ln_B := Random_Row (Merged46, 0.1);
      W.VM_Ds_Up := Random_Row (VFeed46 * Merged46, 0.2);
      W.VM_Ds_Up_B := Random_Row (VFeed46, 0.1);
      W.VM_Ds_Down := Random_Row (Width_M * VFeed46, 0.2);
      W.VM_Ds_Down_B := Random_Row (Width_M, 0.1);
      W.MM_Norm_W := Gain_Row (Merged46);
      W.MM_Norm_B := Random_Row (Merged46, 0.1);
      W.MM_Up := Random_Row (Merged46 * Merged46, 0.2);
      W.MM_Up_B := Random_Row (Merged46, 0.1);
      W.MM_Down := Random_Row (Text46 * Merged46, 0.2);
      W.MM_Down_B := Random_Row (Text46, 0.1);
      return W;
   end Fresh_Minicpm46_Weights;

   procedure Write_Minicpm46_Projector
     (Path : String; W : Minicpm46_Weights; Kind : String := "minicpmv4_6")
   is
      Builder : Fixtures.Builder;
      File    : B.Byte_Array_Access;
      use Ada.Streams.Stream_IO;
      Handle  : File_Type;

      procedure Tensor
        (Name : String; Dims : Fixtures.Dimension_List; Values : N.Real_Array)
      is
      begin
         Fixtures.Add_Tensor
           (Builder, Name, Dims, G.Type_F32, Fixtures.Encode_F32 (Values));
      end Tensor;
   begin
      Fixtures.Reset (Builder);
      Fixtures.Add_String (Builder, "general.architecture", "clip");
      Fixtures.Add_String (Builder, "clip.projector_type", Kind);
      Fixtures.Add_U32 (Builder, "clip.vision.image_size", Size_M);
      Fixtures.Add_U32 (Builder, "clip.vision.patch_size", Patch_M);
      Fixtures.Add_U32 (Builder, "clip.vision.embedding_length", Width_M);
      Fixtures.Add_U32 (Builder, "clip.vision.feed_forward_length", Feed_M);
      Fixtures.Add_U32 (Builder, "clip.vision.projection_dim", Text46);
      Fixtures.Add_U32 (Builder, "clip.vision.block_count", Blocks_M);
      Fixtures.Add_U32 (Builder, "clip.vision.attention.head_count", Heads_M);
      Fixtures.Add_U32 (Builder, "clip.vision.projector.scale_factor", 4);
      Fixtures.Add_F32
        (Builder, "clip.vision.attention.layer_norm_epsilon", 1.0e-6);
      Fixtures.Begin_Array
        (Builder, "clip.vision.wa_layer_indexes", G.Value_Int32, 1);
      Fixtures.Int32_Element (Builder, Interfaces.Integer_32 (Insert46));
      Fixtures.End_Array (Builder);
      Fixtures.Begin_Array
        (Builder, "clip.vision.image_mean", G.Value_Float32, 3);
      for Channel in 1 .. 3 loop
         Fixtures.Float_Element (Builder, 0.5);
      end loop;
      Fixtures.End_Array (Builder);
      Fixtures.Begin_Array
        (Builder, "clip.vision.image_std", G.Value_Float32, 3);
      for Channel in 1 .. 3 loop
         Fixtures.Float_Element (Builder, 0.5);
      end loop;
      Fixtures.End_Array (Builder);

      Tensor ("v.patch_embd.weight", [Patch_M, Patch_M, 3, Width_M], W.Patch);
      Tensor ("v.patch_embd.bias", [Width_M], W.Patch_B);
      Tensor ("v.position_embd.weight", [Width_M, Bank_M], W.Pos);
      for Index in W.Blocks'Range loop
         declare
            Prefix : constant String :=
              "v.blk." & Model_Runner.Text.Image (Long_Long_Integer (Index))
              & ".";
            Current : Minicpm_Block renames W.Blocks (Index);
         begin
            Tensor (Prefix & "ln1.weight", [Width_M], Current.Ln1_W);
            Tensor (Prefix & "ln1.bias", [Width_M], Current.Ln1_B);
            Tensor (Prefix & "ln2.weight", [Width_M], Current.Ln2_W);
            Tensor (Prefix & "ln2.bias", [Width_M], Current.Ln2_B);
            Tensor (Prefix & "attn_q.weight", [Width_M, Width_M], Current.Q);
            Tensor (Prefix & "attn_q.bias", [Width_M], Current.Q_B);
            Tensor (Prefix & "attn_k.weight", [Width_M, Width_M], Current.K);
            Tensor (Prefix & "attn_k.bias", [Width_M], Current.K_B);
            Tensor (Prefix & "attn_v.weight", [Width_M, Width_M], Current.V);
            Tensor (Prefix & "attn_v.bias", [Width_M], Current.V_B);
            Tensor (Prefix & "attn_out.weight", [Width_M, Width_M], Current.O);
            Tensor (Prefix & "attn_out.bias", [Width_M], Current.O_B);
            Tensor (Prefix & "ffn_up.weight", [Width_M, Feed_M], Current.Up);
            Tensor (Prefix & "ffn_up.bias", [Feed_M], Current.Up_B);
            Tensor (Prefix & "ffn_down.weight", [Feed_M, Width_M], Current.Down);
            Tensor (Prefix & "ffn_down.bias", [Width_M], Current.Down_B);
         end;
      end loop;
      Tensor ("v.post_ln.weight", [Width_M], W.Post_W);
      Tensor ("v.post_ln.bias", [Width_M], W.Post_B);

      Tensor ("v.vit_merger.ln1.weight", [Width_M], W.VM_Ln1_W);
      Tensor ("v.vit_merger.ln1.bias", [Width_M], W.VM_Ln1_B);
      Tensor ("v.vit_merger.attn_q.weight", [Width_M, Width_M], W.VM_Q);
      Tensor ("v.vit_merger.attn_q.bias", [Width_M], W.VM_Q_B);
      Tensor ("v.vit_merger.attn_k.weight", [Width_M, Width_M], W.VM_K);
      Tensor ("v.vit_merger.attn_k.bias", [Width_M], W.VM_K_B);
      Tensor ("v.vit_merger.attn_v.weight", [Width_M, Width_M], W.VM_V);
      Tensor ("v.vit_merger.attn_v.bias", [Width_M], W.VM_V_B);
      Tensor ("v.vit_merger.attn_out.weight", [Width_M, Width_M], W.VM_O);
      Tensor ("v.vit_merger.attn_out.bias", [Width_M], W.VM_O_B);
      Tensor ("v.vit_merger.ds_ln.weight", [Merged46], W.VM_Ds_Ln_W);
      Tensor ("v.vit_merger.ds_ln.bias", [Merged46], W.VM_Ds_Ln_B);
      Tensor ("v.vit_merger.ds_ffn_up.weight", [Merged46, VFeed46],
              W.VM_Ds_Up);
      Tensor ("v.vit_merger.ds_ffn_up.bias", [VFeed46], W.VM_Ds_Up_B);
      Tensor ("v.vit_merger.ds_ffn_down.weight", [VFeed46, Width_M],
              W.VM_Ds_Down);
      Tensor ("v.vit_merger.ds_ffn_down.bias", [Width_M], W.VM_Ds_Down_B);

      Tensor ("mm.input_norm.weight", [Merged46], W.MM_Norm_W);
      Tensor ("mm.input_norm.bias", [Merged46], W.MM_Norm_B);
      Tensor ("mm.up.weight", [Merged46, Merged46], W.MM_Up);
      Tensor ("mm.up.bias", [Merged46], W.MM_Up_B);
      Tensor ("mm.down.weight", [Merged46, Text46], W.MM_Down);
      Tensor ("mm.down.bias", [Text46], W.MM_Down_B);

      Fixtures.Build (Builder, File);
      Create (Handle, Out_File, Path);
      declare
         Block : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (File.all'Length))
           with Import, Address => File.all'Address;
      begin
         Write (Handle, Block);
      end;
      Close (Handle);
      B.Free (File);
   end Write_Minicpm46_Projector;

   --  The one row the small 4.6 merger should make of a picture, in
   --  binary64, computed straight from the spec on the fixed square grid.
   procedure Minicpm46_Reference_Rows
     (W : Minicpm46_Weights; Picture : Images.Raster;
      Rows : out N.Wide_Real_Array)
   is
      subtype WR is N.Wide_Real;
      Grid : constant Natural := Size_M / Patch_M;
      NP0  : constant Natural := Grid * Grid;
      S1   : constant Natural := Grid / 2;
      NP1  : constant Natural := S1 * S1;
      S2   : constant Natural := S1 / 2;
      Target : constant Natural := Grid * Patch_M;
      Eps  : constant WR := 1.0e-6;
      Pixels : Images.Raster;

      --  Token states at each stage, flat (token * Width_M + dim).
      X  : N.Wide_Real_Array (0 .. N.Element_Count (NP0 * Width_M - 1)) :=
        [others => 0.0];
      X2 : N.Wide_Real_Array (0 .. N.Element_Count (NP1 * Width_M - 1)) :=
        [others => 0.0];

      function GELU (Value : WR) return WR
      is (0.5 * Value
          * (1.0 + Wide_Math.Tanh
                     (0.797_884_560_802_865_4
                      * (Value + 0.044_715 * Value * Value * Value))));

      function Erf_GELU (Value : WR) return WR is
         P  : constant WR := 0.327_591_1;
         A1 : constant WR := 0.254_829_592;
         A2 : constant WR := -0.284_496_736;
         A3 : constant WR := 1.421_413_741;
         A4 : constant WR := -1.453_152_027;
         A5 : constant WR := 1.061_405_429;
         X0 : constant WR := Value * 0.707_106_781_186_547_5;
         Z  : constant WR := abs X0;
         T  : constant WR := 1.0 / (1.0 + P * Z);
         Y  : constant WR :=
           1.0 - (((((A5 * T + A4) * T) + A3) * T + A2) * T + A1) * T
                 * Wide_Math.Exp (-Z * Z);
         Erf : constant WR := (if X0 < 0.0 then -Y else Y);
      begin
         return 0.5 * Value * (1.0 + Erf);
      end Erf_GELU;

      --  Layer-norm one row of Wide wide, in place across a flat array.
      procedure Norm_Row
        (A : in out N.Wide_Real_Array; At_Row, Wide : Natural;
         Gain, Bias : N.Real_Array)
      is
         Mean, Variance : WR := 0.0;
      begin
         for D in 0 .. Wide - 1 loop
            Mean := Mean + A (N.Element_Count (At_Row + D));
         end loop;
         Mean := Mean / WR (Wide);
         for D in 0 .. Wide - 1 loop
            Variance := Variance
              + (A (N.Element_Count (At_Row + D)) - Mean) ** 2;
         end loop;
         Variance := Variance / WR (Wide);
         for D in 0 .. Wide - 1 loop
            A (N.Element_Count (At_Row + D)) :=
              (A (N.Element_Count (At_Row + D)) - Mean)
              / Wide_Math.Sqrt (Variance + Eps)
              * WR (Gain (N.Element_Count (D)))
              + WR (Bias (N.Element_Count (D)));
         end loop;
      end Norm_Row;

      --  One SigLIP block over Count tokens of Width_M held in Buf.
      procedure Block_Pass
        (Buf : in out N.Wide_Real_Array; Count : Natural;
         Blk : Minicpm_Block)
      is
         H : N.Wide_Real_Array (Buf'Range);
         Q, Kk, Vv, A : N.Wide_Real_Array (Buf'Range);
         Fh : N.Wide_Real_Array (0 .. N.Element_Count (Count * Feed_M - 1));
         function WI (P, D : Natural) return N.Element_Count
         is (N.Element_Count (P * Width_M + D));
      begin
         H := Buf;
         for P in 0 .. Count - 1 loop
            Norm_Row (H, P * Width_M, Width_M, Blk.Ln1_W, Blk.Ln1_B);
         end loop;
         for P in 0 .. Count - 1 loop
            for R in 0 .. Width_M - 1 loop
               declare
                  Sq : WR := WR (Blk.Q_B (N.Element_Count (R)));
                  Sk : WR := WR (Blk.K_B (N.Element_Count (R)));
                  Sv : WR := WR (Blk.V_B (N.Element_Count (R)));
               begin
                  for C in 0 .. Width_M - 1 loop
                     Sq := Sq + H (WI (P, C))
                       * WR (Blk.Q (N.Element_Count (R * Width_M + C)));
                     Sk := Sk + H (WI (P, C))
                       * WR (Blk.K (N.Element_Count (R * Width_M + C)));
                     Sv := Sv + H (WI (P, C))
                       * WR (Blk.V (N.Element_Count (R * Width_M + C)));
                  end loop;
                  Q (WI (P, R)) := Sq; Kk (WI (P, R)) := Sk;
                  Vv (WI (P, R)) := Sv;
               end;
            end loop;
         end loop;
         for Hd in 0 .. Heads_M - 1 loop
            for P in 0 .. Count - 1 loop
               declare
                  Scores : array (0 .. Count - 1) of WR;
                  Largest, Total : WR;
               begin
                  for O in 0 .. Count - 1 loop
                     Scores (O) := 0.0;
                     for D in 0 .. Head_M - 1 loop
                        Scores (O) := Scores (O)
                          + Q (WI (P, Hd * Head_M + D))
                          * Kk (WI (O, Hd * Head_M + D));
                     end loop;
                     Scores (O) := Scores (O) / Wide_Math.Sqrt (WR (Head_M));
                  end loop;
                  Largest := Scores (0);
                  for O in 1 .. Count - 1 loop
                     Largest := WR'Max (Largest, Scores (O));
                  end loop;
                  Total := 0.0;
                  for O in 0 .. Count - 1 loop
                     Scores (O) := Wide_Math.Exp (Scores (O) - Largest);
                     Total := Total + Scores (O);
                  end loop;
                  for D in 0 .. Head_M - 1 loop
                     declare
                        Sum : WR := 0.0;
                     begin
                        for O in 0 .. Count - 1 loop
                           Sum := Sum
                             + Scores (O) / Total * Vv (WI (O, Hd * Head_M + D));
                        end loop;
                        A (WI (P, Hd * Head_M + D)) := Sum;
                     end;
                  end loop;
               end;
            end loop;
         end loop;
         for P in 0 .. Count - 1 loop
            for R in 0 .. Width_M - 1 loop
               declare
                  Sum : WR := WR (Blk.O_B (N.Element_Count (R)));
               begin
                  for C in 0 .. Width_M - 1 loop
                     Sum := Sum + A (WI (P, C))
                       * WR (Blk.O (N.Element_Count (R * Width_M + C)));
                  end loop;
                  Buf (WI (P, R)) := Buf (WI (P, R)) + Sum;
               end;
            end loop;
         end loop;
         H := Buf;
         for P in 0 .. Count - 1 loop
            Norm_Row (H, P * Width_M, Width_M, Blk.Ln2_W, Blk.Ln2_B);
         end loop;
         for P in 0 .. Count - 1 loop
            for R in 0 .. Feed_M - 1 loop
               declare
                  Sum : WR := WR (Blk.Up_B (N.Element_Count (R)));
               begin
                  for C in 0 .. Width_M - 1 loop
                     Sum := Sum + H (WI (P, C))
                       * WR (Blk.Up (N.Element_Count (R * Width_M + C)));
                  end loop;
                  Fh (N.Element_Count (P * Feed_M + R)) := GELU (Sum);
               end;
            end loop;
            for R in 0 .. Width_M - 1 loop
               declare
                  Sum : WR := WR (Blk.Down_B (N.Element_Count (R)));
               begin
                  for C in 0 .. Feed_M - 1 loop
                     Sum := Sum + Fh (N.Element_Count (P * Feed_M + C))
                       * WR (Blk.Down (N.Element_Count (R * Feed_M + C)));
                  end loop;
                  Buf (WI (P, R)) := Buf (WI (P, R)) + Sum;
               end;
            end loop;
         end loop;
      end Block_Pass;

      function Corner (G, I, J, N4 : Natural) return Natural
      is (case N4 is
             when 0 => (2 * I) * G + (2 * J),
             when 1 => (2 * I) * G + (2 * J + 1),
             when 2 => (2 * I + 1) * G + (2 * J),
             when others => (2 * I + 1) * G + (2 * J + 1));
   begin
      Images.Resample (Picture, Target, Target, Pixels);
      for PY in 0 .. Grid - 1 loop
         for PX in 0 .. Grid - 1 loop
            declare
               P : constant Natural := PY * Grid + PX;
               Bucket : constant Natural :=
                 (70 * PY / Grid) * 70 + (70 * PX / Grid);
            begin
               for R in 0 .. Width_M - 1 loop
                  declare
                     Sum : WR := WR (W.Patch_B (N.Element_Count (R)))
                       + WR (W.Pos (N.Element_Count (Bucket * Width_M + R)));
                  begin
                     for C in 0 .. 2 loop
                        for KY in 0 .. Patch_M - 1 loop
                           for KX in 0 .. Patch_M - 1 loop
                              declare
                                 Value : constant WR :=
                                   (WR (Pixel (Pixels, PX * Patch_M + KX,
                                               PY * Patch_M + KY, C)) / 255.0
                                    - 0.5) / 0.5;
                                 Idx : constant Natural :=
                                   C * Patch_M * Patch_M + KY * Patch_M + KX;
                              begin
                                 Sum := Sum + Value
                                   * WR (W.Patch (N.Element_Count
                                                    (R * Elements_M + Idx)));
                              end;
                           end loop;
                        end loop;
                     end loop;
                     X (N.Element_Count (P * Width_M + R)) := Sum;
                  end;
               end loop;
            end;
         end loop;
      end loop;
      Images.Free (Pixels);

      for Index in 0 .. Insert46 loop
         Block_Pass (X, NP0, W.Blocks (Index));
      end loop;

      --  The windowed merger's self-attention: each two-by-two window's
      --  four tokens attend only among themselves.
      declare
         H : N.Wide_Real_Array (X'Range) := X;
         Q, Kk, Vv, A : N.Wide_Real_Array (X'Range);
         function WI (P, D : Natural) return N.Element_Count
         is (N.Element_Count (P * Width_M + D));
      begin
         for P in 0 .. NP0 - 1 loop
            Norm_Row (H, P * Width_M, Width_M, W.VM_Ln1_W, W.VM_Ln1_B);
         end loop;
         for P in 0 .. NP0 - 1 loop
            for R in 0 .. Width_M - 1 loop
               declare
                  Sq : WR := WR (W.VM_Q_B (N.Element_Count (R)));
                  Sk : WR := WR (W.VM_K_B (N.Element_Count (R)));
                  Sv : WR := WR (W.VM_V_B (N.Element_Count (R)));
               begin
                  for C in 0 .. Width_M - 1 loop
                     Sq := Sq + H (WI (P, C))
                       * WR (W.VM_Q (N.Element_Count (R * Width_M + C)));
                     Sk := Sk + H (WI (P, C))
                       * WR (W.VM_K (N.Element_Count (R * Width_M + C)));
                     Sv := Sv + H (WI (P, C))
                       * WR (W.VM_V (N.Element_Count (R * Width_M + C)));
                  end loop;
                  Q (WI (P, R)) := Sq; Kk (WI (P, R)) := Sk;
                  Vv (WI (P, R)) := Sv;
               end;
            end loop;
         end loop;
         for I in 0 .. S1 - 1 loop
            for J in 0 .. S1 - 1 loop
               declare
                  T4 : constant array (0 .. 3) of Natural :=
                    [Corner (Grid, I, J, 0), Corner (Grid, I, J, 1),
                     Corner (Grid, I, J, 2), Corner (Grid, I, J, 3)];
               begin
                  for Hd in 0 .. Heads_M - 1 loop
                     for Ai in 0 .. 3 loop
                        declare
                           Sc : array (0 .. 3) of WR;
                           Largest, Total : WR;
                        begin
                           for Bi in 0 .. 3 loop
                              Sc (Bi) := 0.0;
                              for D in 0 .. Head_M - 1 loop
                                 Sc (Bi) := Sc (Bi)
                                   + Q (WI (T4 (Ai), Hd * Head_M + D))
                                   * Kk (WI (T4 (Bi), Hd * Head_M + D));
                              end loop;
                              Sc (Bi) := Sc (Bi) / Wide_Math.Sqrt (WR (Head_M));
                           end loop;
                           Largest := Sc (0);
                           for Bi in 1 .. 3 loop
                              Largest := WR'Max (Largest, Sc (Bi));
                           end loop;
                           Total := 0.0;
                           for Bi in 0 .. 3 loop
                              Sc (Bi) := Wide_Math.Exp (Sc (Bi) - Largest);
                              Total := Total + Sc (Bi);
                           end loop;
                           for D in 0 .. Head_M - 1 loop
                              declare
                                 Sum : WR := 0.0;
                              begin
                                 for Bi in 0 .. 3 loop
                                    Sum := Sum + Sc (Bi) / Total
                                      * Vv (WI (T4 (Bi), Hd * Head_M + D));
                                 end loop;
                                 A (WI (T4 (Ai), Hd * Head_M + D)) := Sum;
                              end;
                           end loop;
                        end;
                     end loop;
                  end loop;
               end;
            end loop;
         end loop;
         for P in 0 .. NP0 - 1 loop
            for R in 0 .. Width_M - 1 loop
               declare
                  Sum : WR := WR (W.VM_O_B (N.Element_Count (R)));
               begin
                  for C in 0 .. Width_M - 1 loop
                     Sum := Sum + A (WI (P, C))
                       * WR (W.VM_O (N.Element_Count (R * Width_M + C)));
                  end loop;
                  X (WI (P, R)) := X (WI (P, R)) + Sum;
               end;
            end loop;
         end loop;
      end;

      --  The windowed merger's two-by-two downsample.
      for I in 0 .. S1 - 1 loop
         for J in 0 .. S1 - 1 loop
            declare
               O : constant Natural := I * S1 + J;
               Joined : N.Wide_Real_Array (0 .. Merged46 - 1);
               Mean   : N.Wide_Real_Array (0 .. Width_M - 1) := [others => 0.0];
               Up     : N.Wide_Real_Array (0 .. VFeed46 - 1);
            begin
               for N4 in 0 .. 3 loop
                  declare
                     Src : constant Natural := Corner (Grid, I, J, N4) * Width_M;
                  begin
                     for D in 0 .. Width_M - 1 loop
                        Joined (N.Element_Count (N4 * Width_M + D)) :=
                          X (N.Element_Count (Src + D));
                        Mean (N.Element_Count (D)) :=
                          Mean (N.Element_Count (D))
                          + X (N.Element_Count (Src + D)) * 0.25;
                     end loop;
                  end;
               end loop;
               Norm_Row (Joined, 0, Merged46, W.VM_Ds_Ln_W, W.VM_Ds_Ln_B);
               for R in 0 .. VFeed46 - 1 loop
                  declare
                     Sum : WR := WR (W.VM_Ds_Up_B (N.Element_Count (R)));
                  begin
                     for C in 0 .. Merged46 - 1 loop
                        Sum := Sum + Joined (N.Element_Count (C))
                          * WR (W.VM_Ds_Up
                                  (N.Element_Count (R * Merged46 + C)));
                     end loop;
                     Up (N.Element_Count (R)) := GELU (Sum);
                  end;
               end loop;
               for R in 0 .. Width_M - 1 loop
                  declare
                     Sum : WR := WR (W.VM_Ds_Down_B (N.Element_Count (R)));
                  begin
                     for C in 0 .. VFeed46 - 1 loop
                        Sum := Sum + Up (N.Element_Count (C))
                          * WR (W.VM_Ds_Down
                                  (N.Element_Count (R * VFeed46 + C)));
                     end loop;
                     X2 (N.Element_Count (O * Width_M + R)) :=
                       Sum + Mean (N.Element_Count (R));
                  end;
               end loop;
            end;
         end loop;
      end loop;

      for Index in Insert46 + 1 .. Blocks_M - 1 loop
         Block_Pass (X2, NP1, W.Blocks (Index));
      end loop;

      for P in 0 .. NP1 - 1 loop
         Norm_Row (X2, P * Width_M, Width_M, W.Post_W, W.Post_B);
      end loop;

      --  The final two-by-two merge and the downsample-MLP head.
      for I in 0 .. S2 - 1 loop
         for J in 0 .. S2 - 1 loop
            declare
               O : constant Natural := I * S2 + J;
               Joined : N.Wide_Real_Array (0 .. Merged46 - 1);
               Up     : N.Wide_Real_Array (0 .. Merged46 - 1);
            begin
               for N4 in 0 .. 3 loop
                  declare
                     Src : constant Natural := Corner (S1, I, J, N4) * Width_M;
                  begin
                     for D in 0 .. Width_M - 1 loop
                        Joined (N.Element_Count (N4 * Width_M + D)) :=
                          X2 (N.Element_Count (Src + D));
                     end loop;
                  end;
               end loop;
               Norm_Row (Joined, 0, Merged46, W.MM_Norm_W, W.MM_Norm_B);
               for R in 0 .. Merged46 - 1 loop
                  declare
                     Sum : WR := WR (W.MM_Up_B (N.Element_Count (R)));
                  begin
                     for C in 0 .. Merged46 - 1 loop
                        Sum := Sum + Joined (N.Element_Count (C))
                          * WR (W.MM_Up (N.Element_Count (R * Merged46 + C)));
                     end loop;
                     Up (N.Element_Count (R)) := Erf_GELU (Sum);
                  end;
               end loop;
               for R in 0 .. Text46 - 1 loop
                  declare
                     Sum : WR := WR (W.MM_Down_B (N.Element_Count (R)));
                  begin
                     for C in 0 .. Merged46 - 1 loop
                        Sum := Sum + Up (N.Element_Count (C))
                          * WR (W.MM_Down (N.Element_Count (R * Merged46 + C)));
                     end loop;
                     Rows (N.Element_Count (O * Text46 + R)) := Sum;
                  end;
               end loop;
            end;
         end loop;
      end loop;
   end Minicpm46_Reference_Rows;

   procedure The_Minicpmv46_Projector_Encodes_As_The_Reference
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      W : Minicpm46_Weights_Access := Fresh_Minicpm46_Weights;
      Picture : Images.Raster;
      Status  : E.Error_Info;
      Wanted  : N.Wide_Real_Array (0 .. Text46 - 1);
      Rows    : T.Real_Array_Access;
      Grid_Rows, Grid_Columns : Natural;
      Eyes    : Vision.Encoder;
   begin
      declare
         Data : B.Byte_Array (1 .. 3 * 20 * 20);
      begin
         for Y in 0 .. 19 loop
            for X in 0 .. 19 loop
               declare
                  At_Pixel : constant B.Byte_Count :=
                    B.Byte_Count (3 * (Y * 20 + X)) + 1;
               begin
                  Data (At_Pixel) := B.Byte (X * 12);
                  Data (At_Pixel + 1) := B.Byte (Y * 12);
                  Data (At_Pixel + 2) :=
                    (if X in 5 .. 12 and then Y in 6 .. 15 then 240 else 30);
               end;
            end loop;
         end loop;
         Images.Decode (Bytes_Of ("P6 20 20 255 ") & Data, "test", Picture,
                        Status);
         Assert (E.Is_Ok (Status), "the 4.6 test picture was refused");
      end;

      Minicpm46_Reference_Rows (W.all, Picture, Wanted);

      Write_Minicpm46_Projector ("obj/vision-minicpm46.gguf", W.all);
      Vision.Open (Eyes, "obj/vision-minicpm46.gguf", Status);
      Assert (E.Is_Ok (Status), "the small 4.6 merger did not open: "
              & E.Error_Code'Image (Status.Code));
      Assert (Vision.Is_Ready (Eyes)
              and then Vision.Fixed_Rows (Eyes)
              and then not Vision.Placed_Rows (Eyes)
              and then Vision.Rows_Per_Picture (Eyes) = NP2_M
              and then Vision.Row_Width (Eyes) = Text46
              and then Vision.Projector (Eyes) = "minicpmv4_6",
              "the small 4.6 merger's shape was misread");

      Vision.Encode (Eyes, Picture, null, Rows, Grid_Rows, Grid_Columns,
                     Status => Status);
      Assert (E.Is_Ok (Status), "the small 4.6 merger did not encode: "
              & E.Error_Code'Image (Status.Code));
      Assert (Rows /= null and then Rows.all'Length = NP2_M * Text46,
              "the 4.6 merger made the wrong number of rows");
      for J in 0 .. N.Element_Count (NP2_M * Text46 - 1) loop
         Assert (abs (N.Wide_Real (Rows (J)) - Wanted (J))
                 <= 1.0e-4 * (1.0 + abs Wanted (J)),
                 "4.6 row element" & N.Element_Count'Image (J) & " is "
                 & N.Real'Image (Rows (J)) & " where the reference has "
                 & N.Wide_Real'Image (Wanted (J)));
      end loop;
      T.Free (Rows);
      Vision.Close (Eyes);
      Images.Free (Picture);
      Free (W);
   end The_Minicpmv46_Projector_Encodes_As_The_Reference;

   ----------
   -- Name --
   ----------

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("pictures and the vision encoder");
   end Name;

   --------------------
   -- Register_Tests --
   --------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Pictures_Decode_And_Resample'Access,
         "a PNG, a JPEG and a PPM decode to their pixels, what is none of "
         & "them is refused by name, and resampling averages what it drops");
      Register_Routine
        (T, The_Projector_Encodes_As_The_Reference'Access,
         "a projector written small encodes a picture to the rows a plain "
         & "computation of the same network gives, however its halves are "
         & "named, and a projector of another kind is refused");
      Register_Routine
        (T, The_Qwen_Projector_Encodes_As_The_Reference'Access,
         "a Qwen projector written small encodes a picture to the rows a "
         & "plain computation of the same network gives, as a grid of its "
         & "windows, scales a small picture up to the least rows, and the "
         & "cubic filter resamples as PIL does");
      Register_Routine
        (T, Placed_Rows_Turn_By_Row_And_Column'Access,
         "a model whose positions have three parts turns a picture's rows "
         & "by its start, their row and their column, goes on after it from "
         & "the grid's longer side, and keeps the places through a rewind "
         & "and a snapshot");
      Register_Routine
        (T, A_Pictures_Rows_See_Each_Other'Access,
         "a picture's rows attend to each other both ways, and a text "
         & "position after them is causal still");
      Register_Routine
        (T, The_Minicpm_Projector_Encodes_As_The_Reference'Access,
         "a MiniCPM-V resampler written small encodes a picture to the "
         & "rows a plain computation of the same network gives -- the "
         & "SigLIP encoder placed by the bucketed bank and the resampler "
         & "cross-attention -- and a resampler of another kind is refused");
      Register_Routine
        (T, The_Minicpmv46_Projector_Encodes_As_The_Reference'Access,
         "a MiniCPM-V 4.6 windowed merger written small encodes a picture "
         & "to the rows a plain computation of the same network gives -- the "
         & "SigLIP encoder, the windowed self-attention, the two-by-two "
         & "downsample, and the final merge through the error-function head");
      Register_Routine
        (T, Pictures_Stand_Behind_Their_Markers'Access,
         "a picture's rows take the positions its marker opens in the "
         & "prompt, and a prompt marking more or fewer pictures than were "
         & "given is refused");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, A_Pair_Of_Frames_Encodes_As_The_Reference'Access,
         "a pair of frames encodes to the rows the plain computation "
         & "gives with each frame through its own temporal weights, a "
         & "frame paired with itself is the still, the fit follows the "
         & "reference video processor's rule, and Gemma 3's projector "
         & "refuses a video by name");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, A_Videos_Frames_Are_Fetched_As_The_Reference_Takes_Them'Access,
         "a video's frames are sampled as the reference samples, a "
         & "directory of pictures is fetched at the fit, and a video file "
         & "is decoded through the host's libraries where it has them");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, A_Videos_Slots_Stand_Among_Their_Seconds'Access,
         "a video's marker opens out to its slots, each among the seconds "
         & "it stands at as the reference processor writes them and each "
         & "behind its own rows, and markers of the wrong kinds are refused");
   end Register_Tests;

end Tests.Vision_Cases;
