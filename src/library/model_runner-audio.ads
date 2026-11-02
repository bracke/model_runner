with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Tensors;

--  Sound, as a speech model hears it: one channel of samples at sixteen
--  kilohertz, each between minus one and one.
--
--  Whatever a recording was made as -- stereo, forty-four point one
--  kilohertz, twenty-four-bit integers -- is brought to that here, and
--  nothing past this package sees another form. The channels are averaged,
--  which is what the reference's ffmpeg does when it is asked for one; the
--  rate is changed by a band-limited interpolation (a sinc windowed by
--  Kaiser's window, sixteen zero crossings a side, cut off at 0.97 of the
--  lower Nyquist rate), which is ffmpeg's resampler's design without its
--  every detail: a recording at another rate is heard alike, not to the
--  bit alike.
--
--  WAV is the one container read, and in it the encodings a WAV of speech
--  is written in: integers of 8, 16, 24 or 32 bits and floats of 32 or 64,
--  plain or in the extensible header, any number of channels up to
--  sixteen. Anything else -- a compressed encoding, a header that says
--  more data than the file holds -- is refused by name. Compressed
--  formats are not read.
--
--  Bounds: a recording is refused before it is decoded when it is longer
--  than the caller allows, so a file states its length and does not get
--  to allocate past it.
--
--  Task safety: pure functions on their arguments; the samples returned
--  are the caller's.
package Model_Runner.Audio is

   subtype Real is Model_Runner.Numerics.Real;
   subtype Real_Array is Model_Runner.Numerics.Real_Array;
   subtype Element_Count is Model_Runner.Numerics.Element_Count;

   use type Model_Runner.Numerics.Element_Count;

   --  The rate every sample past this package is at.
   Canonical_Rate : constant := 16_000;

   --  The rates and channels a recording may come in.
   Min_Rate     : constant := 1_000;
   Max_Rate     : constant := 384_000;
   Max_Channels : constant := 16;

   --  What a WAV file's header says.
   type Encoding is (Integer_PCM, Float_PCM);

   type Wave_Header is record
      Kind     : Encoding := Integer_PCM;
      Rate     : Positive := Canonical_Rate;
      Channels : Positive := 1;
      Bits     : Positive := 16;
      --  Frames: a sample of every channel.
      Frames   : Element_Count := 0;
      --  Where the samples begin and how many bytes they take, from the
      --  file's first byte.
      Data_At     : Model_Runner.Bytes.Byte_Count := 0;
      Data_Length : Model_Runner.Bytes.Byte_Count := 0;
   end record;

   --  Read a WAV file's header.
   --
   --  @param Data The file's bytes.
   --  @param Header What it says.
   --  @param Status Success, or IO_Audio_Unreadable with a detail saying
   --    what the header is that is not read.
   procedure Read_Header
     (Data   : Model_Runner.Bytes.Byte_Array;
      Header : out Wave_Header;
      Status : out Model_Runner.Errors.Error_Info);

   --  A WAV file's samples, one channel at the canonical rate.
   --
   --  @param Data The file's bytes.
   --  @param Max_Seconds The longest recording taken.
   --  @param Samples Receives them, indexed from 0; null on failure.
   --  @param Status Success; IO_Audio_Unreadable for a file this does not
   --    read; IO_Audio_Too_Long for one longer than Max_Seconds;
   --    Memory_Allocation_Failed.
   procedure Decode_Wave
     (Data        : Model_Runner.Bytes.Byte_Array;
      Max_Seconds : Positive;
      Samples     : out Model_Runner.Tensors.Real_Array_Access;
      Status      : out Model_Runner.Errors.Error_Info);

   --  The same, from a file.
   --
   --  @param Path The file.
   --  @param Max_Seconds The longest recording taken.
   --  @param Samples Receives them, indexed from 0; null on failure.
   --  @param Status As Decode_Wave's, and IO_Open_Failed, IO_Read_Failed
   --    or IO_File_Too_Large for a file that cannot be read whole; each
   --    names the path.
   procedure Read_Wave
     (Path        : String;
      Max_Seconds : Positive;
      Samples     : out Model_Runner.Tensors.Real_Array_Access;
      Status      : out Model_Runner.Errors.Error_Info);

   --  How many samples a recording of Count samples at From_Rate becomes
   --  at To_Rate: Count times the ratio, rounded up.
   --
   --  @param Count Samples in.
   --  @param From_Rate Their rate.
   --  @param To_Rate The rate wanted.
   --  @return Samples out.
   function Resampled_Length
     (Count : Element_Count; From_Rate, To_Rate : Positive) return Element_Count;

   --  Change a recording's rate.
   --
   --  @param Input The samples, at From_Rate.
   --  @param From_Rate Their rate.
   --  @param To_Rate The rate wanted.
   --  @param Output Receives Resampled_Length of them.
   procedure Resample
     (Input     : Real_Array;
      From_Rate : Positive;
      To_Rate   : Positive;
      Output    : out Real_Array)
   with Pre => Output'Length = Resampled_Length (Input'Length, From_Rate, To_Rate);

   --  Interleaved 16-bit samples of some channels, as a microphone gives
   --  them, mixed to one channel of values between minus one and one.
   --
   --  @param Data Little-endian 16-bit samples, a frame of each channel
   --    after another.
   --  @param Channels How many channels a frame holds.
   --  @param Output Receives one value a frame.
   procedure Mix_Signed_16
     (Data     : Model_Runner.Bytes.Byte_Array;
      Channels : Positive;
      Output   : out Real_Array)
   with Pre => Output'Length = Element_Count (Data'Length) / Element_Count (2 * Channels);

end Model_Runner.Audio;
