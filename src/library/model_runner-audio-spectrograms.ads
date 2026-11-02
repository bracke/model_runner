with Model_Runner.Errors;
with Model_Runner.Tensors;

--  The log-Mel spectrogram a Whisper model reads.
--
--  What the reference does (openai/whisper, audio.py), step by step, and
--  what is done here the same way:
--
--  1. The samples, at sixteen kilohertz, with Padding zeros after them --
--     the reference appends thirty seconds, so the last window of speech
--     always has a whole window of frames after it.
--  2. A short-time Fourier transform: windows of 400 samples, a hop of
--     160 (a frame every ten milliseconds), each window weighted by the
--     periodic Hann window, 0.5 - 0.5 cos (2 pi n / 400). The signal is
--     centred: 200 samples reflected about each end before the first
--     window, so frame f is centred on sample 160 f. The transform's last
--     frame is dropped, as the reference drops it, so a recording of L
--     samples (padding counted) is L / 160 frames.
--  3. The power of each of the 201 bins.
--  4. Mel filters: Slaney's scale, linear to 1 kHz and logarithmic past,
--     each triangular filter scaled to unit area (librosa's
--     filters.mel (sr = 16000, n_fft = 400), which is what the reference's
--     mel_filters.npz holds), 80 of them or 128.
--  5. log10 of each, at least 1e-10; then everything held to no less than
--     the largest value less 8 -- the largest over the whole recording,
--     padding included -- and mapped by (x + 4) / 4.
--
--  The values are laid out as the reference lays them: a row of frames for
--  each filter, filter m's frame f at m * Frames + f.
--
--  Task safety: pure; each call has its own transform plan.
package Model_Runner.Audio.Spectrograms is

   --  Samples a window takes, and a frame's hop.
   Window_Length : constant := 400;
   Hop_Length    : constant := 160;

   --  Frequency bins a window's power has: Window_Length / 2 + 1.
   Bins : constant := Window_Length / 2 + 1;

   --  The filter banks a model may ask for.
   subtype Mel_Count is Positive range 1 .. 256;

   --  The filters: filter m's weight for bin k at m * Bins + k.
   --
   --  @param Mels How many filters.
   --  @param Into Receives Mels * Bins weights.
   procedure Mel_Filters (Mels : Mel_Count; Into : out Real_Array)
   with Pre => Into'Length = Element_Count (Mels) * Bins;

   --  Frames a recording of Samples samples with Padding zeros after it
   --  becomes.
   --
   --  @param Samples Samples in the recording.
   --  @param Padding Zeros after it.
   --  @return The frames.
   function Frames_Of (Samples, Padding : Element_Count) return Element_Count
   is ((Samples + Padding) / Hop_Length);

   --  The log-Mel spectrogram of a recording.
   --
   --  @param Samples The recording, at Canonical_Rate.
   --  @param Mels How many filters.
   --  @param Padding Zeros appended before the transform.
   --  @param Into Receives Mels rows of Frames_Of values, indexed from 0;
   --    null on failure.
   --  @param Status Success, Memory_Allocation_Failed, or
   --    IO_Audio_Unreadable for a recording too short to reflect about
   --    its ends (fewer than 201 samples, padding counted).
   procedure Log_Mel
     (Samples : Real_Array;
      Mels    : Mel_Count;
      Padding : Element_Count;
      Into    : out Model_Runner.Tensors.Real_Array_Access;
      Status  : out Model_Runner.Errors.Error_Info);

end Model_Runner.Audio.Spectrograms;
