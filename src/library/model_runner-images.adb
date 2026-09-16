with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;
with Interfaces;

with Jpeglib;
with Jpeglib.Decoding;
with Jpeglib.Errors;
with Jpeglib.Images;
with Jpeglib.Results;
with Jpeglib.Streams;
with Zlib;

package body Model_Runner.Images is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;

   --  Byte arrays of the two libraries, on the heap: a picture's bytes
   --  are too many for a stack frame.
   type Z_Bytes_Access is access Zlib.Byte_Array;
   procedure Free is new Ada.Unchecked_Deallocation
     (Zlib.Byte_Array, Z_Bytes_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Jpeglib.Streams.Byte_Array, Jpeglib.Streams.Byte_Array_Access);

   use type B.Byte_Count;
   use type B.Byte_Array;
   use type B.Byte_Array_Access;
   use type Ada.Directories.File_Kind;
   use type Ada.Directories.File_Size;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;

   --  The refusal every decoder here ends in: the file's name and what
   --  the decoder objected to, in a word or two.
   procedure Refuse
     (Status : out E.Error_Info; Name : String; Detail : String) is
   begin
      Status := E.Make (E.IO_Image_Unreadable);
      E.Add_Text (Status, "path", Name, E.Param_Path);
      E.Add_Text (Status, "detail", Detail, E.Param_Identifier);
   end Refuse;

   --  A raster of the given size, its pixels zeroed, or an empty one when
   --  the size is beyond what a picture may hold or the allocation failed.
   procedure Make (Width, Height : Natural; Result : out Raster) is
   begin
      Result := (others => <>);
      if Width = 0 or else Height = 0
        or else Long_Long_Integer (Width) * Long_Long_Integer (Height)
                > Max_Pixels
      then
         return;
      end if;
      --  Indexed from zero, as the spec promises, which is not what
      --  Bytes.Allocate hands out.
      begin
         Result.Pixels :=
           new B.Byte_Array'
             (0 .. 3 * B.Byte_Count (Width) * B.Byte_Count (Height) - 1 => 0);
      exception
         when Storage_Error =>
            Result.Pixels := null;
      end;
      if Result.Pixels /= null then
         Result.Width  := Width;
         Result.Height := Height;
      end if;
   end Make;

   ----------
   -- Crop --
   ----------

   procedure Crop
     (Source : Raster;
      Left   : Natural;
      Top    : Natural;
      Width  : Positive;
      Height : Positive;
      Result : out Raster)
   is
      Columns : constant Integer :=
        Integer'Min (Width, Source.Width - Left);
      Rows    : constant Integer :=
        Integer'Min (Height, Source.Height - Top);
   begin
      Result := (others => <>);
      if Source.Pixels = null or else Columns <= 0 or else Rows <= 0 then
         return;
      end if;

      Make (Columns, Rows, Result);
      if Result.Pixels = null then
         return;
      end if;

      for Y in 0 .. Rows - 1 loop
         declare
            From : constant B.Byte_Count :=
              3 * (B.Byte_Count (Top + Y) * B.Byte_Count (Source.Width)
                   + B.Byte_Count (Left));
            Into : constant B.Byte_Count :=
              3 * B.Byte_Count (Y) * B.Byte_Count (Columns);
            Span : constant B.Byte_Count := 3 * B.Byte_Count (Columns);
         begin
            Result.Pixels.all (Into .. Into + Span - 1) :=
              Source.Pixels.all (From .. From + Span - 1);
         end;
      end loop;
   end Crop;

   ------------------
   -- Pan_And_Scan --
   ------------------

   function Pan_And_Scan
     (Width     : Positive;
      Height    : Positive;
      Min_Crop  : Positive := 256;
      Max_Crops : Positive := 4;
      Min_Ratio : Float := 1.2) return Tiling
   is
      Longer  : constant Positive := Positive'Max (Width, Height);
      Shorter : constant Positive := Positive'Min (Width, Height);
      Ratio   : constant Float := Float (Longer) / Float (Shorter);

      --  The ratio rounded half up, held to what the shortest crop
      --  allows, to at least two and to the most allowed -- in that
      --  order, which is the reference's and matters where the picture is
      --  narrow: a picture 300 wide with a minimum of 256 rounds to one
      --  crop, is raised to two, and is then found too narrow to cut.
      Count : Natural := Natural (Float'Floor (Ratio + 0.5));
   begin
      if Ratio < Min_Ratio then
         return Uncut;
      end if;

      Count := Natural'Min (Longer / Min_Crop, Count);
      Count := Natural'Max (2, Count);
      Count := Natural'Min (Max_Crops, Count);

      declare
         Along_Longer  : constant Positive :=
           (Longer + Count - 1) / Count;
      begin
         if Positive'Min (Along_Longer, Shorter) < Min_Crop then
            return Uncut;
         end if;
      end;

      if Width >= Height then
         return (Across => Count, Down => 1);
      else
         return (Across => 1, Down => Count);
      end if;
   end Pan_And_Scan;

   -----------------
   -- Crop_Bounds --
   -----------------

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
   is
      Each_Wide : constant Positive := (Width + Grid.Across - 1) / Grid.Across;
      Each_Tall : constant Positive := (Height + Grid.Down - 1) / Grid.Down;
   begin
      Left := Column * Each_Wide;
      Top  := Row * Each_Tall;
      Crop_Width  := Positive'Min (Each_Wide, Width - Left);
      Crop_Height := Positive'Min (Each_Tall, Height - Top);
   end Crop_Bounds;

   ----------
   -- Free --
   ----------

   procedure Free (Item : in out Raster) is
   begin
      B.Free (Item.Pixels);
      Item.Width  := 0;
      Item.Height := 0;
   end Free;

   ---------
   -- PNG --
   ---------

   --  A PNG: chunks of a length, a type, the bytes and a checksum. IHDR
   --  says the shape, PLTE the palette, IDAT -- as many as the writer
   --  chose -- the deflated scanlines, each led by the filter that was
   --  applied to it. The checksums are not verified: a damaged file
   --  inflates wrongly or not at all, and either is refused for what it
   --  is rather than for its checksum.
   procedure Decode_PNG
     (Data   : B.Byte_Array;
      Name   : String;
      Result : out Raster;
      Status : out E.Error_Info)
   is
      function Big_Endian (At_Byte : B.Byte_Index) return Interfaces.Unsigned_32
      is (Interfaces.Shift_Left (Interfaces.Unsigned_32 (Data (At_Byte)), 24)
          or Interfaces.Shift_Left
               (Interfaces.Unsigned_32 (Data (At_Byte + 1)), 16)
          or Interfaces.Shift_Left
               (Interfaces.Unsigned_32 (Data (At_Byte + 2)), 8)
          or Interfaces.Unsigned_32 (Data (At_Byte + 3)));

      Width, Height : Natural := 0;
      Depth         : Natural := 0;
      Colour        : Natural := 0;
      Interlaced    : Boolean := False;
      Channels      : Natural := 0;
      Header_Seen   : Boolean := False;

      Palette       : B.Byte_Array (0 .. 3 * 256 - 1) := [others => 0];
      Palette_Size  : Natural := 0;

      --  The deflated bytes, gathered from every IDAT chunk in order.
      Deflated      : Z_Bytes_Access :=
        new Zlib.Byte_Array (0 .. Natural (Data'Length));
      Deflated_Last : Integer := -1;

      Cursor : B.Byte_Index := Data'First + 8;

      procedure Refuse (Detail : String) is
      begin
         Free (Deflated);
         Free (Result);
         Refuse (Status, Name, Detail);
      end Refuse;
   begin
      Result := (others => <>);
      Status := E.Success;

      while Cursor + 8 <= Data'Last + 1 loop
         declare
            Length : constant Interfaces.Unsigned_32 := Big_Endian (Cursor);
            Kind   : constant String :=
              [Character'Val (Data (Cursor + 4)),
               Character'Val (Data (Cursor + 5)),
               Character'Val (Data (Cursor + 6)),
               Character'Val (Data (Cursor + 7))];
            Body_At : constant B.Byte_Index := Cursor + 8;
         begin
            if Long_Long_Integer (Length) > Long_Long_Integer (Data'Last)
              or else Body_At + B.Byte_Count (Length) + 4 > Data'Last + 1
            then
               Refuse ("png chunk");
               return;
            end if;

            if Kind = "IHDR" then
               if Length /= 13 then
                  Refuse ("png header");
                  return;
               end if;
               Width  := Natural (Big_Endian (Body_At));
               Height := Natural (Big_Endian (Body_At + 4));
               Depth  := Natural (Data (Body_At + 8));
               Colour := Natural (Data (Body_At + 9));
               Interlaced := Data (Body_At + 12) = 1;
               Header_Seen := True;

               Channels :=
                 (case Colour is
                    when 0 => 1, when 2 => 3, when 3 => 1,
                    when 4 => 2, when 6 => 4, when others => 0);
               if Channels = 0
                 or else Depth not in 1 | 2 | 4 | 8 | 16
                 or else (Depth < 8 and then Colour not in 0 | 3)
                 or else (Depth = 16 and then Colour = 3)
                 or else Data (Body_At + 10) /= 0
                 or else Data (Body_At + 11) /= 0
                 or else Data (Body_At + 12) > 1
               then
                  Refuse ("png colour type");
                  return;
               end if;
               if Width = 0 or else Height = 0
                 or else Long_Long_Integer (Width) * Long_Long_Integer (Height)
                         > Max_Pixels
               then
                  Refuse ("png size");
                  return;
               end if;

            elsif Kind = "PLTE" then
               if Length mod 3 /= 0 or else Length > 3 * 256 then
                  Refuse ("png palette");
                  return;
               end if;
               Palette_Size := Natural (Length) / 3;
               for Index in 0 .. B.Byte_Count (Length) - 1 loop
                  Palette (Index) := Data (Body_At + Index);
               end loop;

            elsif Kind = "IDAT" then
               for Index in 0 .. B.Byte_Count (Length) - 1 loop
                  Deflated_Last := Deflated_Last + 1;
                  Deflated (Deflated_Last) :=
                    Zlib.Byte (Data (Body_At + Index));
               end loop;

            elsif Kind = "IEND" then
               exit;
            end if;

            Cursor := Body_At + B.Byte_Count (Length) + 4;
         end;
      end loop;

      if not Header_Seen or else Deflated_Last < 0 then
         Refuse ("png chunks");
         return;
      end if;
      if Colour = 3 and then Palette_Size = 0 then
         Refuse ("png palette");
         return;
      end if;

      declare
         Inflate_Status : Zlib.Status_Code;
         Rows : Z_Bytes_Access :=
           new Zlib.Byte_Array'
             (Zlib.Inflate (Deflated (0 .. Deflated_Last), Inflate_Status));
         Unfiltered : Z_Bytes_Access :=
           new Zlib.Byte_Array (Rows'Range);

         --  Bytes a scanline of a given width takes, before its filter
         --  byte, and bytes a whole pixel takes for the filter's purposes.
         function Line_Bytes (Columns : Natural) return Natural
         is ((Columns * Channels * Depth + 7) / 8);
         Pixel_Bytes : constant Positive :=
           Positive'Max (1, Channels * Depth / 8);

         --  The sample of channel C at pixel X of an unfiltered line held
         --  at Line_At, scaled to a byte for a grey sample and left as an
         --  index for a palette's.
         function Sample
           (Line_At : Natural; X : Natural; C : Natural) return B.Byte
         is
            Position : constant Natural := X * Channels + C;
         begin
            case Depth is
               when 8 =>
                  return B.Byte (Unfiltered (Line_At + Position));
               when 16 =>
                  return B.Byte (Unfiltered (Line_At + 2 * Position));
               when others =>
                  declare
                     Bit   : constant Natural := Position * Depth;
                     Held  : constant Interfaces.Unsigned_8 :=
                       Interfaces.Unsigned_8 (Unfiltered (Line_At + Bit / 8));
                     Shift : constant Natural := 8 - Depth - (Bit mod 8);
                     Mask  : constant Interfaces.Unsigned_8 :=
                       Interfaces.Unsigned_8 (2 ** Depth - 1);
                     Raw   : constant Interfaces.Unsigned_8 :=
                       Interfaces.Shift_Right (Held, Shift) and Mask;
                  begin
                     if Colour = 3 then
                        return B.Byte (Raw);
                     end if;
                     return B.Byte (Raw) * B.Byte (255 / (2 ** Depth - 1));
                  end;
            end case;
         end Sample;

         --  Store pixel (X, Y) from the sample at line Line_At, column
         --  Column of the line.
         procedure Put (Line_At : Natural; Column : Natural; X, Y : Natural) is
            At_Pixel : constant B.Byte_Index :=
              3 * (B.Byte_Count (Y) * B.Byte_Count (Width) + B.Byte_Count (X));
         begin
            case Colour is
               when 0 | 4 =>
                  declare
                     Grey : constant B.Byte := Sample (Line_At, Column, 0);
                  begin
                     Result.Pixels (At_Pixel .. At_Pixel + 2) :=
                       [Grey, Grey, Grey];
                  end;
               when 3 =>
                  declare
                     Index : constant B.Byte_Count :=
                       B.Byte_Count (Sample (Line_At, Column, 0));
                  begin
                     if Index < B.Byte_Count (Palette_Size) then
                        Result.Pixels (At_Pixel .. At_Pixel + 2) :=
                          [Palette (3 * Index), Palette (3 * Index + 1),
                           Palette (3 * Index + 2)];
                     end if;
                  end;
               when others =>
                  Result.Pixels (At_Pixel .. At_Pixel + 2) :=
                    [Sample (Line_At, Column, 0),
                     Sample (Line_At, Column, 1),
                     Sample (Line_At, Column, 2)];
            end case;
         end Put;

         --  Unfilter the lines of one image or pass, Columns pixels wide
         --  and Lines high, starting at From in the inflated bytes, and
         --  store its pixels at X_Start + x * X_Step, Y_Start + y * Y_Step.
         --  From is left past the pass.
         procedure Pass
           (From    : in out Natural;
            Columns : Natural;
            Lines   : Natural;
            X_Start, X_Step, Y_Start, Y_Step : Natural;
            Ok      : out Boolean)
         is
            Span : constant Natural := Line_Bytes (Columns);
            Previous : Natural := 0;
            Has_Previous : Boolean := False;
         begin
            Ok := True;
            for Line in 0 .. Lines - 1 loop
               if Rows'First + From + Span + 1 > Rows'Last + 1 then
                  Ok := False;
                  return;
               end if;
               declare
                  Filter  : constant Zlib.Byte := Rows (Rows'First + From);
                  Line_At : constant Natural := Rows'First + From + 1;
               begin
                  for Index in 0 .. Span - 1 loop
                     declare
                        Left : constant Integer :=
                          (if Index >= Pixel_Bytes
                           then Integer (Unfiltered (Line_At + Index - Pixel_Bytes))
                           else 0);
                        Up : constant Integer :=
                          (if Has_Previous
                           then Integer (Unfiltered (Previous + Index))
                           else 0);
                        Up_Left : constant Integer :=
                          (if Has_Previous and then Index >= Pixel_Bytes
                           then Integer (Unfiltered (Previous + Index - Pixel_Bytes))
                           else 0);
                        Raw : constant Integer :=
                          Integer (Rows (Line_At + Index));
                        Guess : Integer;
                     begin
                        case Filter is
                           when 0 => Guess := 0;
                           when 1 => Guess := Left;
                           when 2 => Guess := Up;
                           when 3 => Guess := (Left + Up) / 2;
                           when 4 =>
                              declare
                                 P  : constant Integer := Left + Up - Up_Left;
                                 PA : constant Integer := abs (P - Left);
                                 PB : constant Integer := abs (P - Up);
                                 PC : constant Integer := abs (P - Up_Left);
                              begin
                                 Guess :=
                                   (if PA <= PB and then PA <= PC then Left
                                    elsif PB <= PC then Up
                                    else Up_Left);
                              end;
                           when others =>
                              Ok := False;
                              return;
                        end case;
                        Unfiltered (Line_At + Index) :=
                          Zlib.Byte ((Raw + Guess) mod 256);
                     end;
                  end loop;

                  for X in 0 .. Columns - 1 loop
                     Put (Line_At, X, X_Start + X * X_Step,
                          Y_Start + Line * Y_Step);
                  end loop;

                  Previous := Line_At;
                  Has_Previous := True;
                  From := Line_At + Span - Rows'First;
               end;
            end loop;
         end Pass;

         From : Natural := 0;
         Ok   : Boolean;
      begin
         if Zlib."/=" (Inflate_Status, Zlib.Ok) then
            Free (Rows);
            Free (Unfiltered);
            Refuse ("png deflate");
            return;
         end if;

         Make (Width, Height, Result);
         if Result.Pixels = null then
            Free (Rows);
            Free (Unfiltered);
            Refuse ("png size");
            return;
         end if;

         if not Interlaced then
            Pass (From, Width, Height, 0, 1, 0, 1, Ok);
         else
            --  Adam7: seven passes, each a lattice of the picture, each
            --  filtered as a small picture of its own.
            declare
               X_Starts : constant array (1 .. 7) of Natural :=
                 [0, 4, 0, 2, 0, 1, 0];
               Y_Starts : constant array (1 .. 7) of Natural :=
                 [0, 0, 4, 0, 2, 0, 1];
               X_Steps  : constant array (1 .. 7) of Natural :=
                 [8, 8, 4, 4, 2, 2, 1];
               Y_Steps  : constant array (1 .. 7) of Natural :=
                 [8, 8, 8, 4, 4, 2, 2];
            begin
               Ok := True;
               for P in 1 .. 7 loop
                  declare
                     Columns : constant Natural :=
                       (if Width > X_Starts (P)
                        then (Width - X_Starts (P) + X_Steps (P) - 1)
                             / X_Steps (P)
                        else 0);
                     Lines : constant Natural :=
                       (if Height > Y_Starts (P)
                        then (Height - Y_Starts (P) + Y_Steps (P) - 1)
                             / Y_Steps (P)
                        else 0);
                  begin
                     if Columns > 0 and then Lines > 0 then
                        Pass (From, Columns, Lines,
                              X_Starts (P), X_Steps (P),
                              Y_Starts (P), Y_Steps (P), Ok);
                        exit when not Ok;
                     end if;
                  end;
               end loop;
            end;
         end if;

         Free (Rows);
         Free (Unfiltered);
         if not Ok then
            Refuse ("png scanlines");
            return;
         end if;
         Free (Deflated);
      end;
   end Decode_PNG;

   ----------
   -- JPEG --
   ----------

   procedure Decode_JPEG
     (Data   : B.Byte_Array;
      Name   : String;
      Result : out Raster;
      Status : out E.Error_Info)
   is
      Input   : Jpeglib.Streams.Byte_Array_Access :=
        new Jpeglib.Streams.Byte_Array (1 .. Natural (Data'Length));
      Source  : aliased Jpeglib.Streams.Memory_Source;
      Decoder : Jpeglib.Decoding.Decoder;
      Outcome : Jpeglib.Results.Result;
   begin
      Result := (others => <>);
      Status := E.Success;

      for Index in Input'Range loop
         Input (Index) :=
           Jpeglib.Byte (Data (Data'First + B.Byte_Count (Index - 1)));
      end loop;

      Jpeglib.Streams.Open
        (Source, Jpeglib.Streams.Const_Byte_Array_Access (Input));
      Jpeglib.Decoding.Initialize
        (Decoder, Source'Access,
         (Output_Format => Jpeglib.Images.RGB_24,
          Apply_Exif_Orientation => True,
          others => <>));

      Outcome := Jpeglib.Decoding.Read_Header (Decoder);
      if not Jpeglib.Results.Succeeded (Outcome) then
         Jpeglib.Decoding.Finalize (Decoder);
         Free (Input);
         Refuse (Status, Name,
                 "jpeg " & Jpeglib.Errors.Error_Code'Image
                             (Outcome.First_Error.Code));
         return;
      end if;

      declare
         Info : constant Jpeglib.Decoding.Image_Info :=
           Jpeglib.Decoding.Header (Decoder);
         Width  : constant Natural := Natural (Info.Width);
         Height : constant Natural := Natural (Info.Height);
      begin
         if not Info.Height_Defined
           or else Long_Long_Integer (Width) * Long_Long_Integer (Height)
                   > Max_Pixels
         then
            Jpeglib.Decoding.Finalize (Decoder);
            Free (Input);
            Refuse (Status, Name, "jpeg size");
            return;
         end if;

         declare
            Row_Bytes : constant Natural := 3 * Width;
            Output : Jpeglib.Streams.Byte_Array_Access :=
              new Jpeglib.Streams.Byte_Array'
                (1 .. Row_Bytes * Height => 0);
            View : Jpeglib.Images.Mutable_Image_View :=
              (Descriptor =>
                 (Width  => Info.Width,
                  Height => Info.Height,
                  Format => Jpeglib.Images.RGB_24,
                  Stride => Jpeglib.Row_Stride (Row_Bytes),
                  Accessible_Bytes => Jpeglib.Byte_Count (Output'Length)),
               Storage => Output);

            --  The codec keeps every coefficient of the picture on its
            --  stack -- two hundred and fifty-six bytes a block, a block
            --  for every sixty-four samples -- which is seventy megabytes
            --  for a twelve-megapixel photograph and more than a task's
            --  stack holds. So it runs on a task of its own, with a stack
            --  sized for the picture: eight bytes a pixel and sixteen
            --  megabytes besides, reserved rather than touched.
            Room : constant Natural :=
              16 * 1024 * 1024 + 8 * Width * Height;
            Raised : Boolean := False;

            task Decoding is
               pragma Storage_Size (Room);
            end Decoding;

            task body Decoding is
            begin
               Outcome := Jpeglib.Decoding.Decode_Image (Decoder, View);
            exception
               when others =>
                  Raised := True;
            end Decoding;
         begin
            --  Waited for here: a block whose task has not ended is not
            --  left.
            while not Decoding'Terminated loop
               delay 0.001;
            end loop;
            if Raised then
               Outcome := Jpeglib.Results.Failure
                 (Jpeglib.Errors.Internal_Invariant_Failed);
            end if;
            Jpeglib.Decoding.Finalize (Decoder);
            Free (Input);
            if not Jpeglib.Results.Succeeded (Outcome) then
               Free (Output);
               Refuse (Status, Name,
                       "jpeg " & Jpeglib.Errors.Error_Code'Image
                                   (Outcome.First_Error.Code));
               return;
            end if;

            Make (Width, Height, Result);
            if Result.Pixels = null then
               Free (Output);
               Refuse (Status, Name, "jpeg size");
               return;
            end if;
            for Index in Output'Range loop
               Result.Pixels (B.Byte_Count (Index - 1)) :=
                 B.Byte (Output (Index));
            end loop;
            Free (Output);
         end;
      end;
   end Decode_JPEG;

   ---------
   -- PPM --
   ---------

   --  P6 is rows of red, green and blue bytes and P5 rows of grey ones,
   --  after a header of the magic, the width, the height and the largest
   --  sample, separated by blanks and with # comments allowed between.
   procedure Decode_PPM
     (Data   : B.Byte_Array;
      Name   : String;
      Result : out Raster;
      Status : out E.Error_Info)
   is
      Cursor : B.Byte_Index := Data'First + 2;
      Grey   : constant Boolean := Data (Data'First + 1) = Character'Pos ('5');

      --  The next decimal number after blanks and comments, or -1.
      function Next_Number return Integer is
         Value : Integer := -1;
      begin
         loop
            exit when Cursor > Data'Last;
            if Data (Cursor) = Character'Pos ('#') then
               while Cursor <= Data'Last
                 and then Data (Cursor) /= Character'Pos (ASCII.LF)
               loop
                  Cursor := Cursor + 1;
               end loop;
            elsif Data (Cursor) in 9 | 10 | 13 | 32 then
               Cursor := Cursor + 1;
            else
               exit;
            end if;
         end loop;
         while Cursor <= Data'Last
           and then Data (Cursor) in Character'Pos ('0') .. Character'Pos ('9')
         loop
            if Value < 0 then
               Value := 0;
            end if;
            exit when Value > Max_Pixels;
            Value := Value * 10 + Integer (Data (Cursor) - Character'Pos ('0'));
            Cursor := Cursor + 1;
         end loop;
         return Value;
      end Next_Number;

      Width   : constant Integer := Next_Number;
      Height  : constant Integer := Next_Number;
      Largest : constant Integer := Next_Number;
   begin
      Result := (others => <>);
      Status := E.Success;

      if Width <= 0 or else Height <= 0 or else Largest /= 255
        or else Long_Long_Integer (Width) * Long_Long_Integer (Height)
                > Max_Pixels
      then
         Refuse (Status, Name, "ppm header");
         return;
      end if;

      --  One blank after the largest sample, then the bytes.
      Cursor := Cursor + 1;
      declare
         Per_Pixel : constant B.Byte_Count := (if Grey then 1 else 3);
         Needed : constant B.Byte_Count :=
           Per_Pixel * B.Byte_Count (Width) * B.Byte_Count (Height);
      begin
         if Cursor + Needed > Data'Last + 1 then
            Refuse (Status, Name, "ppm pixels");
            return;
         end if;
         Make (Width, Height, Result);
         if Result.Pixels = null then
            Refuse (Status, Name, "ppm size");
            return;
         end if;
         if Grey then
            for Index in 0 .. Needed - 1 loop
               Result.Pixels (3 * Index .. 3 * Index + 2) :=
                 [others => Data (Cursor + Index)];
            end loop;
         else
            Result.Pixels.all := Data (Cursor .. Cursor + Needed - 1);
         end if;
      end;
   end Decode_PPM;

   ------------
   -- Decode --
   ------------

   procedure Decode
     (Data   : B.Byte_Array;
      Name   : String;
      Result : out Raster;
      Status : out E.Error_Info)
   is
      First : constant B.Byte_Index := Data'First;
   begin
      Result := (others => <>);
      if Data'Length >= 8
        and then Data (First .. First + 7)
                 = [16#89#, 16#50#, 16#4E#, 16#47#, 16#0D#, 16#0A#, 16#1A#, 16#0A#]
      then
         Decode_PNG (Data, Name, Result, Status);
      elsif Data'Length >= 3
        and then Data (First .. First + 2) = [16#FF#, 16#D8#, 16#FF#]
      then
         Decode_JPEG (Data, Name, Result, Status);
      elsif Data'Length >= 3
        and then Data (First) = Character'Pos ('P')
        and then Data (First + 1) in Character'Pos ('5') | Character'Pos ('6')
        and then Data (First + 2) in 9 | 10 | 13 | 32
      then
         Decode_PPM (Data, Name, Result, Status);
      else
         Refuse (Status, Name, "format");
      end if;
   end Decode;

   ----------
   -- Load --
   ----------

   procedure Load
     (Path   : String;
      Result : out Raster;
      Status : out E.Error_Info)
   is
      use Ada.Streams.Stream_IO;
      File : File_Type;
   begin
      Result := (others => <>);
      Status := E.Success;

      if not Ada.Directories.Exists (Path)
        or else Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File
      then
         Status := E.Make (E.IO_Open_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      end if;

      if Ada.Directories.Size (Path) > Max_File_Bytes then
         Status := E.Make (E.IO_File_Too_Large);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         E.Add_Integer (Status, "limit", Max_File_Bytes, E.Param_Bytes);
         return;
      end if;

      begin
         Open (File, In_File, Path, Form => "shared=yes");
      exception
         when others =>
            Status := E.Make (E.IO_Open_Failed);
            E.Add_Text (Status, "path", Path, E.Param_Path);
            return;
      end;

      declare
         Length : constant Count := Size (File);
         Data   : B.Byte_Array_Access;
      begin
         B.Allocate (B.Byte_Count (Length), Data);
         if Data = null then
            Close (File);
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;

         declare
            Block : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Length))
              with Import, Address => Data.all'Address;
            Last  : Ada.Streams.Stream_Element_Offset;
         begin
            Read (File, Block, Last);
            Close (File);
            if Last /= Block'Last then
               B.Free (Data);
               Status := E.Make (E.IO_Read_Failed);
               E.Add_Text (Status, "path", Path, E.Param_Path);
               return;
            end if;
         end;

         Decode (Data.all, Path, Result, Status);
         B.Free (Data);
      end;
   exception
      when Occurrence : others =>
         if Is_Open (File) then
            Close (File);
         end if;
         Free (Result);
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         E.Add_Text (Status, "detail", Ada.Exceptions.Exception_Information (Occurrence), E.Param_Identifier);
   end Load;

   --------------
   -- Resample --
   --------------

   procedure Resample
     (Source : Raster;
      Width  : Positive;
      Height : Positive;
      Result : out Raster;
      Filter : Resample_Filter := Triangle)
   is
      --  How far either side of its centre a filter reaches, in source
      --  pixels of a picture not being shrunk: one for the triangle, two
      --  for the cubic.
      Span : constant Positive := (if Filter = Cubic then 2 else 1);
      type Weight is digits 15;
      type Weight_Array is array (Natural range <>) of Weight;

      --  The cubic's shape parameter, PIL's.
      A : constant Weight := -0.5;

      --  The filter's weights for one output position along an axis of
      --  Source_Size mapped to Target_Size: a triangle one pixel wide,
      --  stretched by the shrink where there is one, so that a picture
      --  made smaller averages over every pixel it drops and a picture
      --  made larger interpolates between the two nearest.
      procedure Weights_For
        (Position    : Natural;
         Source_Size : Positive;
         Target_Size : Positive;
         First       : out Natural;
         Taps        : out Weight_Array;
         Count       : out Natural)
      is
         Scale   : constant Weight :=
           Weight (Source_Size) / Weight (Target_Size);
         Stretch : constant Weight := Weight'Max (1.0, Scale);
         Support : constant Weight := Stretch * Weight (Span);
         Centre  : constant Weight := (Weight (Position) + 0.5) * Scale;
         Low  : constant Integer :=
           Integer'Max (0, Integer (Weight'Floor (Centre - Support + 0.5)));
         High : constant Integer :=
           Integer'Min (Source_Size,
                        Integer (Weight'Floor (Centre + Support + 0.5)));
         Total : Weight := 0.0;
      begin
         First := Low;
         Count := 0;
         for Tap in Low .. High - 1 loop
            declare
               Distance : constant Weight :=
                 abs ((Weight (Tap) - Centre + 0.5) / Stretch);
               W : constant Weight :=
                 (case Filter is
                     when Triangle =>
                       (if Distance < 1.0 then 1.0 - Distance else 0.0),
                     when Cubic =>
                       --  PIL's cubic, a = -0.5.
                       (if Distance < 1.0
                        then ((A + 2.0) * Distance - (A + 3.0))
                             * Distance * Distance + 1.0
                        elsif Distance < 2.0
                        then (((Distance - 5.0) * Distance + 8.0) * Distance
                              - 4.0) * A
                        else 0.0));
            begin
               exit when Count >= Taps'Length;
               Taps (Taps'First + Count) := W;
               Total := Total + W;
               Count := Count + 1;
            end;
         end loop;
         if Total > 0.0 then
            for Index in Taps'First .. Taps'First + Count - 1 loop
               Taps (Index) := Taps (Index) / Total;
            end loop;
         end if;
      end Weights_For;

      --  PIL's arithmetic, to the bit: each weight becomes a whole number
      --  of 2 ** 22nds, rounded away from zero, a pixel is the sum of
      --  those times the bytes plus half a unit, shifted down and clipped
      --  to a byte -- after each pass. In floating point a pixel came out
      --  a level from the reference's here and there, and the encoder
      --  behind it turned a level into rows a third apart.
      Precision : constant := 2 ** 22;

      type Fixed_Array is array (Natural range <>) of Long_Long_Integer;

      procedure Fix (Taps : Weight_Array; Count : Natural; Into : out Fixed_Array)
      is
      begin
         for Index in 0 .. Count - 1 loop
            declare
               Scaled : constant Weight :=
                 Taps (Taps'First + Index) * Weight (Precision);
            begin
               Into (Into'First + Index) :=
                 Long_Long_Integer
                   (if Scaled < 0.0 then Weight'Ceiling (Scaled - 0.5)
                    else Weight'Floor (Scaled + 0.5));
            end;
         end loop;
      end Fix;

      function Clipped (Sum : Long_Long_Integer) return Natural
      is (Natural (Long_Long_Integer'Max (0, Long_Long_Integer'Min (255,
            (Sum + Precision / 2) / Precision
            - (if Sum + Precision / 2 < 0
                 and then (Sum + Precision / 2) mod Precision /= 0
               then 1 else 0)))));

      Max_Taps : constant Natural :=
        2 * Span
        * (Natural'Max (1, Natural'Max (Source.Width / Width,
                                        Source.Height / Height)) + 2);
   begin
      Result := (others => <>);
      if Source.Pixels = null or else Source.Width = 0
        or else Source.Height = 0
      then
         return;
      end if;

      Make (Width, Height, Result);
      if Result.Pixels = null then
         return;
      end if;

      declare
         --  The horizontal pass: Source.Height rows of Width pixels,
         --  each a byte's worth, as PIL keeps them between its passes.
         type Row_Values is array (Natural range <>) of Weight;
         type Row_Values_Access is access Row_Values;
         procedure Free is new Ada.Unchecked_Deallocation
           (Row_Values, Row_Values_Access);

         Across : Row_Values_Access :=
           new Row_Values (0 .. 3 * Width * Source.Height - 1);
         Taps   : Weight_Array (0 .. Max_Taps - 1);
         Fixed  : Fixed_Array (0 .. Max_Taps - 1);
         First, Count : Natural;
      begin
         for X in 0 .. Width - 1 loop
            Weights_For (X, Source.Width, Width, First, Taps, Count);
            Fix (Taps, Count, Fixed);
            for Y in 0 .. Source.Height - 1 loop
               for C in 0 .. 2 loop
                  declare
                     Sum : Long_Long_Integer := 0;
                  begin
                     for Tap in 0 .. Count - 1 loop
                        Sum := Sum + Fixed (Tap)
                          * Long_Long_Integer
                              (Source.Pixels
                                 (3 * (B.Byte_Count (Y)
                                       * B.Byte_Count (Source.Width)
                                       + B.Byte_Count (First + Tap))
                                  + B.Byte_Count (C)));
                     end loop;
                     Across (3 * (Y * Width + X) + C) := Weight (Clipped (Sum));
                  end;
               end loop;
            end loop;
         end loop;

         for Y in 0 .. Height - 1 loop
            Weights_For (Y, Source.Height, Height, First, Taps, Count);
            Fix (Taps, Count, Fixed);
            for X in 0 .. Width - 1 loop
               for C in 0 .. 2 loop
                  declare
                     Sum : Long_Long_Integer := 0;
                  begin
                     for Tap in 0 .. Count - 1 loop
                        Sum := Sum + Fixed (Tap)
                          * Long_Long_Integer
                              (Across (3 * ((First + Tap) * Width + X) + C));
                     end loop;
                     Result.Pixels
                       (3 * (B.Byte_Count (Y) * B.Byte_Count (Width)
                             + B.Byte_Count (X)) + B.Byte_Count (C)) :=
                       B.Byte (Clipped (Sum));
                  end;
               end loop;
            end loop;
         end loop;

         Free (Across);
      end;
   end Resample;

end Model_Runner.Images;
