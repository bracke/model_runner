--  Video files, through the host's FFmpeg libraries.
--
--  A video file is a container of encoded frames, and decoding one is a
--  codec's work -- H.264, HEVC, VP9, AV1 -- which no pure-Ada decoder here
--  does or is about to. What every machine that plays a video has is
--  FFmpeg's libraries: libavformat to open the container, libavcodec to
--  decode a stream, libswscale to turn a decoded frame into rows of red,
--  green and blue. They are reached as the device interface is: opened by
--  name at the moment they are first asked for, never linked, so a machine
--  without them runs everything else and refuses a video file by name,
--  with the frames it could be given instead named in the refusal.
--
--  What is read of the libraries' structures is read at stated offsets,
--  as the device backend reads a device's properties: the fields wanted
--  are few and sit at the head of each structure, and they sit at the
--  same offsets in every version from FFmpeg 6.0 to 8.0 -- libavformat
--  60 to 62 -- which was checked against each version's headers. A
--  library of another version is refused by name rather than read at
--  offsets that may not be its own.
--
--  Frames come out in order, one at a time, converted to rows of RGB as
--  the reference reads them through the same libraries. A video's frame
--  count is what the container states, or, where it states none, the
--  packets counted in a pass of their own; its rate is the container's
--  average.
--
--  Task safety: a Reader belongs to one task. Opening the libraries is
--  not reentrant.
with System;

with Model_Runner.Errors;
with Model_Runner.Images;

package Model_Runner.Platform.Video is

   --  Report whether this build can reach the libraries at all, at a
   --  version it reads.
   --
   --  False on a host without them, with another version, or on a host
   --  this build has no body for.
   --
   --  @return True when a video file may be opened.
   function Is_Supported return Boolean;

   --  Why a video file cannot be opened, in words for a refusal: the
   --  library that was not found, or the version that was.
   --
   --  @return The reason, or "" where Is_Supported.
   function Unsupported_Reason return String;

   type Reader is limited private;

   --  Open a video file and find its first video stream.
   --
   --  @param Item Reader to open; closed first.
   --  @param Path The file.
   --  @param Status Success; IO_Video_Unreadable where the libraries are
   --    not there, the file is not a video the libraries read, or it has
   --    no video stream, the detail saying which; IO_Open_Failed where
   --    the file is not there.
   procedure Open
     (Item   : in out Reader;
      Path   : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release the file and the decoder. Idempotent.
   --
   --  @param Item Reader to close.
   procedure Close (Item : in out Reader);

   --  Whether Open succeeded and Close has not been called.
   --
   --  @param Item Reader to inspect.
   --  @return True when frames can be read.
   function Is_Open (Item : Reader) return Boolean;

   --  How many frames the video has: what the container states, or the
   --  packets counted where it states none.
   --
   --  @param Item Open reader.
   --  @return Frames, at least one.
   function Frames (Item : Reader) return Positive;

   --  Frames a second, as the container's average rate has it.
   --
   --  @param Item Open reader.
   --  @return The rate, above nought.
   function Rate (Item : Reader) return Long_Float;

   --  The frames' width, as the last frame Next handed out had it; one
   --  before the first.
   --
   --  @param Item Open reader.
   --  @return Pixels across.
   function Width (Item : Reader) return Positive;

   --  The frames' height, the same way.
   --
   --  @param Item Open reader.
   --  @return Pixels down.
   function Height (Item : Reader) return Positive;

   --  Read the next frame, in the video's order, as rows of RGB.
   --
   --  @param Item Open reader.
   --  @param Picture Receives the frame, which the caller frees; empty
   --    where Done.
   --  @param Done True where the video has no more frames.
   --  @param Status Success, Memory_Allocation_Failed, or
   --    IO_Video_Unreadable where the decoder refused a frame.
   procedure Next
     (Item    : in out Reader;
      Picture : out Model_Runner.Images.Raster;
      Done    : out Boolean;
      Status  : out Model_Runner.Errors.Error_Info);

private

   --  The libraries' objects are held by address and reached through
   --  their functions; nothing of their layout is declared here beyond
   --  the offsets the body reads.
   type Reader is limited record
      Ready    : Boolean := False;
      Format   : System.Address := System.Null_Address;
      Codec    : System.Address := System.Null_Address;
      Frame    : System.Address := System.Null_Address;
      Packet   : System.Address := System.Null_Address;
      Scaler   : System.Address := System.Null_Address;
      Scaled_Format : Integer := -1;
      Scaled_Width, Scaled_Height : Natural := 0;
      Stream   : Integer := -1;
      Count    : Positive := 1;
      Per_Second : Long_Float := 1.0;
      Wide, Tall : Positive := 1;
      Drained  : Boolean := False;
   end record;

end Model_Runner.Platform.Video;
