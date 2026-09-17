--  Which frames of a video the model sees.
--
--  A video file has more frames than a model reads: the reference
--  processor samples them at a rate -- two a second unless told otherwise
--  -- and holds the count between four and seven hundred and sixty-eight,
--  and never above the frames there are. The frames taken are spread
--  evenly over the video, the first and the last among them, each at the
--  nearest whole frame with a half going to the even one, which is what
--  the reference's linspace and round do. What is here is that rule and
--  nothing else: the frames themselves come through the host's libraries,
--  under Model_Runner.Platform.Video, and go to the encoder as a directory
--  of frames would.
with Model_Runner.Errors;
with Model_Runner.Images;
with Model_Runner.Vision;

package Model_Runner.Video is

   --  The reference processor's bounds on the frames sampled, and the
   --  rate it samples at unless told otherwise.
   Least_Frames : constant := 4;
   Most_Frames  : constant := 768;
   Default_Fps  : constant := 2.0;

   type Frame_Indices is array (Positive range <>) of Natural;

   --  How many frames the reference takes of a video: its length in
   --  seconds times the rate, cut to a whole number, held between the
   --  bounds and never above the frames there are.
   --
   --  @param Total How many frames the video has.
   --  @param Rate Frames a second the video runs at.
   --  @param Fps Frames a second to take.
   --  @return The count, one at least.
   function Sampled_Count
     (Total : Positive; Rate : Long_Float; Fps : Long_Float) return Positive;

   --  Which frames those are: Count of them spread evenly from the first
   --  frame to the last, each rounded to the nearest with a half going to
   --  the even one, numbered from nought.
   --
   --  @param Total How many frames the video has.
   --  @param Count How many to take, from Sampled_Count or the caller.
   --  @return The frames' numbers, in order; a frame may recur where
   --    Count is more than Total, as the reference's do.
   function Sampled (Total : Positive; Count : Positive) return Frame_Indices;

   --  Rounding to the nearest whole number with a half going to the even
   --  one: the reference's round, and numpy's.
   --
   --  @param X A number at or above nought.
   --  @return The nearest whole number.
   function Half_Even (X : Long_Float) return Natural;

   --  The frames of a video as the encoder takes them, and when each is.
   type Raster_List is array (Positive range <>) of Model_Runner.Images.Raster;
   type Raster_List_Access is access Raster_List;
   type Seconds_List is array (Positive range <>) of Long_Float;
   type Seconds_List_Access is access Seconds_List;

   --  Most frames a video may be given as, which is the reference's most
   --  frames sampled.
   Most_Given : constant := Most_Frames;

   --  Fetch a video's frames, fitted for the encoder: from a directory of
   --  pictures, one a frame in their names' order taken at Fps a second;
   --  or from a video file, decoded through the host's libraries and
   --  sampled as the reference samples -- Fps a second of the video's own
   --  rate, between the bounds, spread evenly. The first frame decides
   --  the fit for all, by the encoder's rule over the count, and every
   --  frame is resampled to it as it comes, so what is held is the
   --  frames at the encoder's size and no larger.
   --
   --  @param Path A directory of pictures, or a video file.
   --  @param Fps Frames a second: the rate the directory's frames were
   --    taken at, or the rate to take a file's at.
   --  @param Eyes The open encoder the frames are for.
   --  @param Frames Receives the frames, which the caller frees with
   --    Release; null on failure.
   --  @param Times Receives when each frame is, in seconds from the
   --    video's start; null on failure.
   --  @param Fit_Width Receives the frames' width.
   --  @param Fit_Height Receives their height.
   --  @param Status Success, IO_Open_Failed, IO_Image_Unreadable,
   --    IO_Video_Unreadable, Memory_Allocation_Failed,
   --    Arch_Unsupported_Feature where the encoder reads no video or the
   --    frames' sides are past two hundred to one, or
   --    CLI_Option_Out_Of_Range past Most_Given frames.
   procedure Fetch
     (Path   : String;
      Fps    : Long_Float;
      Eyes   : Model_Runner.Vision.Encoder;
      Frames : out Raster_List_Access;
      Times  : out Seconds_List_Access;
      Fit_Width, Fit_Height : out Positive;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release what Fetch handed out. Idempotent.
   --
   --  @param Frames The frames.
   --  @param Times Their times.
   procedure Release
     (Frames : in out Raster_List_Access; Times : in out Seconds_List_Access);

end Model_Runner.Video;
