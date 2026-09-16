with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;
with AUnit.Assertions;
with Interfaces;

with Fixtures;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Generation;
with Model_Runner.Images;
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

         Vision.Encode (Eyes, Picture, null, Rows, Status => Status);
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

      Vision.Encode (Eyes, Picture, null, Rows, Status => Status);
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

         --  With two crops, the marker opens out into the words the
         --  reference sets a cut picture among -- here the pieces "b",
         --  "a" and "b", which the tiny vocabulary spells -- and three
         --  frames: the whole picture's and one a crop.
         declare
            Lead, Bridge, Gap : Vocab.Token_Array (1 .. 8);
            Lead_Count, Bridge_Count, Gap_Count : Natural;
            Expected : Vocab.Token_Array (1 .. 64);
            Count    : Natural := 0;
            Plain    : Natural;
            At_Marker : Natural := Natural'Last;

            procedure Put (Token : Vocab.Token_Id) is
            begin
               Count := Count + 1;
               Expected (Count) := Token;
            end Put;

            procedure Frame is
            begin
               Put (Pictures.Marker);
               for Row in 1 .. Per loop
                  Put (Pictures.Soft);
               end loop;
               Put (Pictures.Closer);
            end Frame;
         begin
            Vocab.Encode (Words.all, "b", False, False, Lead, Lead_Count, Status);
            Vocab.Encode (Words.all, "a", False, False, Bridge, Bridge_Count, Status);
            Vocab.Encode (Words.all, "b", False, False, Gap, Gap_Count, Status);
            Assert (Lead_Count > 0 and then Bridge_Count > 0 and then Gap_Count > 0,
                    "the pieces the crops are set among did not tokenize");

            --  The plain prompt once more, for where its marker stands.
            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "cab", Request, Stop, null, null, null, null, null,
               null, Outcome => Outcome);
            Plain := Outcome.Prompt_Tokens;
            for Index in 0 .. Plain - 1 loop
               if L.Committed_Token (Live, Index) = Pictures.Marker then
                  At_Marker := Index;
                  exit;
               end if;
            end loop;
            for Index in 0 .. At_Marker - 1 loop
               Put (L.Committed_Token (Live, Index));
            end loop;
            for Index in 1 .. Lead_Count loop
               Put (Lead (Index));
            end loop;
            Frame;
            for Index in 1 .. Bridge_Count loop
               Put (Bridge (Index));
            end loop;
            Frame;
            for Index in 1 .. Gap_Count loop
               Put (Gap (Index));
            end loop;
            Frame;
            for Index in At_Marker + 1 .. Plain - 1 loop
               Put (L.Committed_Token (Live, Index));
            end loop;

            Pictures.Crops := new Gen.Crop_Counts'(1 => 2);
            Pictures.Crop_Lead := Model_Runner.Text.To_Bounded ("b");
            Pictures.Crop_Bridge := Model_Runner.Text.To_Bounded ("a");
            Pictures.Crop_Gap := Model_Runner.Text.To_Bounded ("b");
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
            Assert (not Gen."=" (Outcome.Reason, Gen.Runtime_Error),
                    "the run with a cut picture failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));
            Assert (Outcome.Prompt_Tokens = Count,
                    "the prompt with a cut picture is"
                    & Natural'Image (Outcome.Prompt_Tokens) & " tokens, not"
                    & Natural'Image (Count));
            for Index in 1 .. Count loop
               Assert (L.Committed_Token (Live, Index - 1) = Expected (Index),
                       "token" & Natural'Image (Index)
                       & " of the prompt with a cut picture is "
                       & Vocab.Token_Id'Image (L.Committed_Token (Live, Index - 1))
                       & ", not " & Vocab.Token_Id'Image (Expected (Index)));
            end loop;

            --  Without crops for that picture, the words are not written.
            Pictures.Crops.all (1) := 0;
            L.Reset (Live);
            Gen.Release (Outcome);
            Gen.Generate
              (Ready, Live, "cab", Request, Stop, null, null, null, null, null,
               null, Pictures => Pictures, Outcome => Outcome);
            Assert (Outcome.Prompt_Tokens = Plain + Per + 1,
                    "a picture with no crops was set among the words");
            Free (Pictures.Crops);
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
               Given => (Token => Soft, Rows => Rows_A, First => 0),
               Status => Status);
            Assert (E.Is_Ok (Status), "the first batch failed: "
                    & E.Error_Code'Image (Status.Code));
            L.Reset (Live);
            L.Evaluate_Batch
              (Live, Ready, Tokens, Logits, States => States_B,
               Given => (Token => Soft, Rows => Rows_B, First => 0),
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
               Given => (Token => Soft, Rows => Rows_B, First => 0),
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
        (T, A_Pictures_Rows_See_Each_Other'Access,
         "a picture's rows attend to each other both ways, and a text "
         & "position after them is causal still");
      Register_Routine
        (T, Pictures_Stand_Behind_Their_Markers'Access,
         "a picture's rows take the positions its marker opens in the "
         & "prompt, and a prompt marking more or fewer pictures than were "
         & "given is refused");
   end Register_Tests;

end Tests.Vision_Cases;
