with Ada.Calendar;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Numerics;
with Ada.Streams;
with Ada.Numerics.Long_Elementary_Functions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Unchecked_Conversion;
with Interfaces;

with AUnit.Assertions;

with Hostkit;
with Hostkit.Descriptors;
with Hostkit.Pty;
with Hostkit.Spawn;
with AUnit.Test_Cases;

with Model_Runner.Audio;
with Model_Runner.Audio.Spectrograms;
with Model_Runner.Backend.Device;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.Fourier;
with Model_Runner.Numerics;
with Model_Runner.Tensors;
with Model_Runner.Cancellation;
with Model_Runner.Tokenizer;
with Model_Runner.Whisper;
with Model_Runner.Whisper.Decoding;
with Model_Runner.Whisper.Timing;

with Device_Notes;
with Whisper_Fixture;
with Tiny_Model;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.GGUF.Containers;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Speech;
with Model_Runner.CLI.Choosers;
with Model_Runner.CLI.Options;
with Model_Runner.CLI.Speech_Input;

package body Tests.Speech_Cases is

   use AUnit.Assertions;
   use AUnit.Test_Cases.Registration;

   package A renames Model_Runner.Audio;
   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package S renames Model_Runner.Audio.Spectrograms;
   package Ts renames Model_Runner.Tensors;
   package F renames Ada.Numerics.Long_Elementary_Functions;

   use type B.Byte_Count;
   use type E.Error_Code;
   use type N.Element_Count;
   use type N.Real;
   use type N.Wide_Real;
   use type Ts.Real_Array_Access;
   use type Interfaces.Unsigned_32;

   Fixtures : constant String := "fixtures/speech/";

   --  A repeatable sequence in -1 .. 1.
   function Noise (I : Natural) return Long_Float is
      X : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (I) * 1_664_525 + 1_013_904_223;
   begin
      return Long_Float (X mod 20_001) / 10_000.0 - 1.0;
   end Noise;

   -------------
   -- Fourier --
   -------------

   --  The plan's transform is the definition's, for lengths of every kind
   --  of factor: none, a prime, powers of two, and the window's own.
   procedure Fourier_Is_The_Definition
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Lengths : constant array (Positive range <>) of Positive :=
        [1, 2, 3, 4, 5, 7, 12, 30, 97, 128, 400, 512, 1000];
   begin
      for L of Lengths loop
         declare
            Plan   : Model_Runner.Fourier.Plan (L);
            Input  : N.Wide_Real_Array (0 .. N.Element_Count (L) - 1);
            Half   : constant N.Element_Count := N.Element_Count (L / 2);
            Re, Im, Re_D, Im_D : N.Wide_Real_Array (0 .. Half);
            Worst  : Long_Float := 0.0;
            Scale  : Long_Float := 1.0;
         begin
            for I in Input'Range loop
               Input (I) := N.Wide_Real (Noise (Natural (I) + L));
            end loop;
            Assert (not Model_Runner.Fourier.Is_Prepared (Plan), "a plan is ready before it is prepared");
            Model_Runner.Fourier.Prepare (Plan);
            Assert (Model_Runner.Fourier.Is_Prepared (Plan), "a prepared plan says it is not");
            Model_Runner.Fourier.Forward_Real (Plan, Input, Re, Im);
            Model_Runner.Fourier.Forward_Real_Directly (Input, Re_D, Im_D);
            for K in Re'Range loop
               Scale := Long_Float'Max (Scale, Long_Float (abs Re_D (K) + abs Im_D (K)));
               Worst := Long_Float'Max (Worst, Long_Float (abs (Re (K) - Re_D (K)) + abs (Im (K) - Im_D (K))));
            end loop;
            Assert (Worst <= 1.0E-10 * Scale,
                    "a transform of" & L'Image & " points is off its definition by" & Worst'Image);
         end;
      end loop;
   end Fourier_Is_The_Definition;

   --  An impulse is every frequency at once; a constant is the zeroth
   --  alone; a cosine of k cycles is bin k, half the length high.
   procedure Fourier_Of_Known_Signals
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Plan  : Model_Runner.Fourier.Plan (400);
      Input : N.Wide_Real_Array (0 .. 399);
      Re, Im : N.Wide_Real_Array (0 .. 200);
   begin
      Model_Runner.Fourier.Prepare (Plan);

      Input := [others => 0.0];
      Input (0) := 1.0;
      Model_Runner.Fourier.Forward_Real (Plan, Input, Re, Im);
      for K in Re'Range loop
         Assert (abs (Re (K) - 1.0) < 1.0E-12 and then abs Im (K) < 1.0E-12,
                 "an impulse is not flat at bin" & K'Image);
      end loop;

      Input := [others => 2.0];
      Model_Runner.Fourier.Forward_Real (Plan, Input, Re, Im);
      Assert (abs (Re (0) - 800.0) < 1.0E-9, "a constant's zeroth bin is not its sum");
      for K in 1 .. Re'Last loop
         Assert (abs Re (K) + abs Im (K) < 1.0E-9, "a constant has bin" & K'Image);
      end loop;

      for I in Input'Range loop
         Input (I) := N.Wide_Real (F.Cos (2.0 * Ada.Numerics.Pi * 5.0 * Long_Float (I) / 400.0));
      end loop;
      Model_Runner.Fourier.Forward_Real (Plan, Input, Re, Im);
      for K in Re'Range loop
         Assert (abs (Re (K) - (if K = 5 then 200.0 else 0.0)) + abs Im (K) < 1.0E-9,
                 "a cosine of five cycles is not bin five alone, at bin" & K'Image);
      end loop;
   end Fourier_Of_Known_Signals;

   -----------------
   -- Mel filters --
   -----------------

   --  The filters are the reference's mel_filters.npz -- librosa's -- to
   --  binary32: each filter's peak where it is and its area, and filter
   --  zero's single bin.
   procedure Mel_Filters_Are_The_Reference
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Filters : N.Real_Array (0 .. 80 * S.Bins - 1);
      type Peak is record
         Mel, Bin : Natural;
         Value, Area : Long_Float;
      end record;
      --  Read off the reference's file.
      Peaks : constant array (Positive range <>) of Peak :=
        [(0, 1, 0.0248625949, 0.0248625949),
         (1, 2, 0.0228717718, 0.0248625937),
         (10, 10, 0.0199082177, 0.0248625926),
         (40, 43, 0.0147355665, 0.026664861),
         (60, 93, 0.0065910928, 0.0251015415),
         (79, 192, 0.00316471187, 0.0249253398)];
      Total : Long_Float := 0.0;
   begin
      S.Mel_Filters (80, Filters);
      for V of Filters loop
         Total := Total + Long_Float (V);
      end loop;
      Assert (abs (Total - 1.99902409) < 1.0E-6, "the filters sum to" & Total'Image);
      for P of Peaks loop
         declare
            Row  : constant N.Element_Count := N.Element_Count (P.Mel * S.Bins);
            Top  : Natural := 0;
            Area : Long_Float := 0.0;
         begin
            for K in 0 .. S.Bins - 1 loop
               Area := Area + Long_Float (Filters (Row + N.Element_Count (K)));
               if Filters (Row + N.Element_Count (K)) > Filters (Row + N.Element_Count (Top)) then
                  Top := K;
               end if;
            end loop;
            Assert (Top = P.Bin, "filter" & P.Mel'Image & " peaks at bin" & Top'Image);
            Assert (abs (Long_Float (Filters (Row + N.Element_Count (Top))) - P.Value) < 1.0E-8,
                    "filter" & P.Mel'Image & "'s peak is" & Filters (Row + N.Element_Count (Top))'Image);
            Assert (abs (Area - P.Area) < 1.0E-8, "filter" & P.Mel'Image & "'s area is" & Area'Image);
         end;
      end loop;
   end Mel_Filters_Are_The_Reference;

   ---------
   -- WAV --
   ---------

   procedure Put_U16 (Into : in out B.Byte_Array; At_Byte : B.Byte_Count; Value : Natural) is
   begin
      Into (Into'First + At_Byte) := B.Byte (Value mod 256);
      Into (Into'First + At_Byte + 1) := B.Byte (Value / 256 mod 256);
   end Put_U16;

   procedure Put_U32 (Into : in out B.Byte_Array; At_Byte : B.Byte_Count; Value : Interfaces.Unsigned_32) is
   begin
      for I in 0 .. 3 loop
         Into (Into'First + At_Byte + B.Byte_Count (I)) :=
           B.Byte (Interfaces.Shift_Right (Value, 8 * I) and 255);
      end loop;
   end Put_U32;

   --  A WAV file around Data: the plain header, or the extensible one,
   --  saying Tag, Channels, Rate and Bits; Stated the data length it
   --  claims, where not the data's own.
   function Wave
     (Tag : Natural; Channels, Rate, Bits : Positive; Data : B.Byte_Array;
      Extensible : Boolean := False; Stated : Integer := -1) return B.Byte_Array
   is
      Format_Length : constant B.Byte_Count := (if Extensible then 40 else 16);
      Result : B.Byte_Array (1 .. 12 + 8 + Format_Length + 8 + Data'Length) := [others => 0];
      Data_At : constant B.Byte_Count := 12 + 8 + Format_Length;
   begin
      Result (1 .. 4) := B.To_Bytes ("RIFF");
      Put_U32 (Result, 4, Interfaces.Unsigned_32 (Result'Length - 8));
      Result (9 .. 16) := B.To_Bytes ("WAVEfmt ");
      Put_U32 (Result, 16, Interfaces.Unsigned_32 (Format_Length));
      Put_U16 (Result, 20, (if Extensible then 16#FFFE# else Tag));
      Put_U16 (Result, 22, Channels);
      Put_U32 (Result, 24, Interfaces.Unsigned_32 (Rate));
      Put_U32 (Result, 28, Interfaces.Unsigned_32 (Rate * Channels * Bits / 8));
      Put_U16 (Result, 32, Channels * Bits / 8);
      Put_U16 (Result, 34, Bits);
      if Extensible then
         Put_U16 (Result, 36, 22);
         Put_U16 (Result, 38, Bits);
         Put_U16 (Result, 44, Tag);
      end if;
      Result (Result'First + Data_At .. Result'First + Data_At + 3) := B.To_Bytes ("data");
      Put_U32 (Result, Data_At + 4,
               Interfaces.Unsigned_32 (if Stated >= 0 then B.Byte_Count (Stated) else Data'Length));
      Result (Result'First + Data_At + 8 .. Result'Last) := Data;
      return Result;
   end Wave;

   --  Little-endian 16-bit samples of the given values.
   function Sixteen (Values : N.Real_List) return B.Byte_Array is
      Result : B.Byte_Array (1 .. 2 * Values'Length);
   begin
      for I in Values'Range loop
         Put_U16 (Result, B.Byte_Count (2 * (I - Values'First)),
                  Integer (Long_Float (Values (I)) * 32_768.0) mod 65_536);
      end loop;
      return Result;
   end Sixteen;

   --  The encodings a WAV of speech comes in read to the same values:
   --  sixteen-bit, eight-bit, twenty-four-bit stereo mixed, binary32 in
   --  the plain header and in the extensible one.
   procedure Wave_Encodings_Are_Read
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Samples : Ts.Real_Array_Access;
      Status  : E.Error_Info;

      procedure Check (Data : B.Byte_Array; Expected : N.Real_List; Tolerance : N.Real; What : String) is
      begin
         A.Decode_Wave (Data, 60, Samples, Status);
         Assert (E.Is_Ok (Status), What & " was refused: " & Status.Code'Image);
         Assert (Samples.all'Length = Expected'Length, What & " read" & Samples.all'Length'Image & " samples");
         for I in Expected'Range loop
            Assert (abs (Samples (N.Element_Count (I - Expected'First)) - Expected (I)) <= Tolerance,
                    What & " sample" & I'Image & " is" & Samples (N.Element_Count (I - Expected'First))'Image);
         end loop;
         Ts.Free (Samples);
      end Check;

      Values : constant N.Real_List := [0.0, 0.5, -0.5, 0.25, -1.0, 0.75];
   begin
      Check (Wave (1, 1, 16_000, 16, Sixteen (Values)), Values, 0.0, "sixteen-bit");

      declare
         Eight : B.Byte_Array (1 .. Values'Length);
      begin
         for I in Values'Range loop
            Eight (B.Byte_Count (I)) := B.Byte (Integer (Long_Float (Values (I)) * 128.0) + 128);
         end loop;
         Check (Wave (1, 1, 16_000, 8, Eight), Values, 0.0, "eight-bit");
      end;

      --  Stereo, twenty-four bits: left the values, right their negation
      --  halved; mixed, a quarter of each value.
      declare
         Data : B.Byte_Array (1 .. 6 * Values'Length);
         Mixed : N.Real_List (Values'Range);
         procedure Put_24 (At_Byte : B.Byte_Count; V : Long_Float) is
            Raw : constant Integer := Integer (V * 8_388_608.0) mod 16_777_216;
         begin
            Data (At_Byte) := B.Byte (Raw mod 256);
            Data (At_Byte + 1) := B.Byte (Raw / 256 mod 256);
            Data (At_Byte + 2) := B.Byte (Raw / 65_536);
         end Put_24;
      begin
         for I in Values'Range loop
            Put_24 (B.Byte_Count (6 * (I - 1) + 1), Long_Float'Min (Long_Float (Values (I)), 0.999_999));
            Put_24 (B.Byte_Count (6 * (I - 1) + 4), -Long_Float (Values (I)) / 2.0);
            Mixed (I) := Values (I) / 4.0;
         end loop;
         Check (Wave (1, 2, 16_000, 24, Data), Mixed, 1.0E-6, "twenty-four-bit stereo");
      end;

      declare
         Data : B.Byte_Array (1 .. 4 * Values'Length);
         function Bits_Of is new Ada.Unchecked_Conversion (Interfaces.IEEE_Float_32, Interfaces.Unsigned_32);
      begin
         for I in Values'Range loop
            Put_U32 (Data, B.Byte_Count (4 * (I - 1)), Bits_Of (Interfaces.IEEE_Float_32 (Values (I))));
         end loop;
         Check (Wave (3, 1, 16_000, 32, Data), Values, 0.0, "binary32");
         Check (Wave (3, 1, 16_000, 32, Data, Extensible => True), Values, 0.0, "extensible binary32");
      end;

      --  A data length past the file's end is the file's end, whole
      --  samples only.
      Check (Wave (1, 1, 16_000, 16, Sixteen (Values), Stated => 1_000), Values, 0.0, "an overstated length");
   end Wave_Encodings_Are_Read;

   --  What is not read is refused by name, and a recording longer than
   --  allowed before it is decoded.
   procedure Wave_Refusals
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Samples : Ts.Real_Array_Access;
      Status  : E.Error_Info;
      Data    : constant B.Byte_Array := Sixteen ([0.1, 0.2, 0.3, 0.4]);

      procedure Refused (File : B.Byte_Array; Code : E.Error_Code; What : String) is
      begin
         A.Decode_Wave (File, 1, Samples, Status);
         Assert (Status.Code = Code, What & " gave " & Status.Code'Image);
         Assert (Samples = null, What & " left samples");
      end Refused;
   begin
      Refused (B.To_Bytes ("RIFX0000WAVE"), E.IO_Audio_Unreadable, "a big-endian file");
      Refused (B.To_Bytes ("RI"), E.IO_Audio_Unreadable, "a truncated header");
      Refused (Wave (2, 1, 16_000, 16, Data), E.IO_Audio_Unreadable, "ADPCM");
      Refused (Wave (1, 1, 16_000, 12, Data), E.IO_Audio_Unreadable, "twelve-bit samples");
      Refused (Wave (3, 1, 16_000, 16, Data), E.IO_Audio_Unreadable, "sixteen-bit floats");
      Refused (Wave (1, 17, 16_000, 16, Data), E.IO_Audio_Unreadable, "seventeen channels");
      Refused (Wave (1, 1, 500, 16, Data), E.IO_Audio_Unreadable, "a rate of 500");
      Refused (Wave (1, 1, 16_000, 16, Data (1 .. 0)), E.IO_Audio_Unreadable, "no samples");
      declare
         Long : constant B.Byte_Array (1 .. 2 * 16_001) := [others => 0];
      begin
         Refused (Wave (1, 1, 16_000, 16, Long), E.IO_Audio_Too_Long, "a second and a sample");
      end;
   end Wave_Refusals;

   --  A tone at 44.1 kHz brought to sixteen keeps its pitch and its
   --  loudness, and one above the new Nyquist rate is gone.
   procedure Resampling_Keeps_A_Tone
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      function Tone (Hz : Long_Float) return N.Real_Array is
         Result : N.Real_Array (0 .. 44_099);
      begin
         for I in Result'Range loop
            Result (I) := N.Real (0.5 * F.Sin (2.0 * Ada.Numerics.Pi * Hz * Long_Float (I) / 44_100.0));
         end loop;
         return Result;
      end Tone;

      --  The tone's amplitude at Hz in the middle of a resampled second,
      --  by correlating with it.
      function Level (Samples : N.Real_Array; Hz : Long_Float) return Long_Float is
         Si, Co : Long_Float := 0.0;
      begin
         for I in N.Element_Count'(4_000) .. 11_999 loop
            Si := Si + Long_Float (Samples (I)) * F.Sin (2.0 * Ada.Numerics.Pi * Hz * Long_Float (I) / 16_000.0);
            Co := Co + Long_Float (Samples (I)) * F.Cos (2.0 * Ada.Numerics.Pi * Hz * Long_Float (I) / 16_000.0);
         end loop;
         return 2.0 * F.Sqrt (Si * Si + Co * Co) / 8_000.0;
      end Level;

      Low  : constant N.Real_Array := Tone (440.0);
      High : constant N.Real_Array := Tone (12_000.0);
      Out_Low, Out_High : N.Real_Array (0 .. A.Resampled_Length (44_100, 44_100, 16_000) - 1);
   begin
      Assert (Out_Low'Length = 16_000, "a second resampled is" & Out_Low'Length'Image & " samples");
      A.Resample (Low, 44_100, 16_000, Out_Low);
      A.Resample (High, 44_100, 16_000, Out_High);
      Assert (abs (Level (Out_Low, 440.0) - 0.5) < 0.005,
              "a 440 Hz tone came out at" & Level (Out_Low, 440.0)'Image);
      declare
         Peak : N.Real := 0.0;
      begin
         for I in N.Element_Count'(1_000) .. 14_999 loop
            Peak := N.Real'Max (Peak, abs Out_High (I));
         end loop;
         Assert (Peak < 0.005, "a 12 kHz tone passed sixteen kilohertz at" & Peak'Image);
      end;
   end Resampling_Keeps_A_Tone;

   -----------------
   -- Spectrogram --
   -----------------

   --  A recording's log-Mel spectrogram is the reference's: its frame
   --  count, its mean, and a grid of its values.
   procedure Check_Spectrogram (Name : String) is
      Samples : Ts.Real_Array_Access;
      Mel     : Ts.Real_Array_Access;
      Status  : E.Error_Info;
      File    : Ada.Text_IO.File_Type;
      Frames  : N.Element_Count;
      Worst   : Long_Float := 0.0;
   begin
      A.Read_Wave (Fixtures & Name & ".wav", 600, Samples, Status);
      Assert (E.Is_Ok (Status), Name & ".wav was refused: " & Status.Code'Image);
      S.Log_Mel (Samples.all, 80, 480_000, Mel, Status);
      Assert (E.Is_Ok (Status), Name & "'s spectrogram failed: " & Status.Code'Image);
      Frames := S.Frames_Of (Samples.all'Length, 480_000);

      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Fixtures & Name & "-mel.expect", Form => "shared=no");
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line  : constant String := Ada.Text_IO.Get_Line (File);
            Space : Natural := 0;
         begin
            if Line'Length > 0 and then Line (Line'First) /= '#' then
               for I in Line'Range loop
                  if Line (I) = ' ' then
                     Space := I;
                     exit;
                  end if;
               end loop;
               if Line (Line'First .. Space - 1) = "frames" then
                  Assert (N.Element_Count'Value (Line (Space + 1 .. Line'Last)) = Frames,
                          Name & " is" & Frames'Image & " frames");
               elsif Line (Line'First .. Space - 1) = "mean" then
                  declare
                     Sum : Long_Float := 0.0;
                  begin
                     for V of Mel.all loop
                        Sum := Sum + Long_Float (V);
                     end loop;
                     Sum := Sum / Long_Float (Mel.all'Length);
                     Assert (abs (Sum - Long_Float'Value (Line (Space + 1 .. Line'Last))) < 1.0E-5,
                             Name & "'s mean is" & Sum'Image);
                  end;
               else
                  declare
                     Rest   : constant String := Line (Space + 1 .. Line'Last);
                     Second : Natural := 0;
                  begin
                     for I in Rest'Range loop
                        if Rest (I) = ' ' then
                           Second := I;
                           exit;
                        end if;
                     end loop;
                     declare
                        M : constant N.Element_Count := N.Element_Count'Value (Line (Line'First .. Space - 1));
                        Fr : constant N.Element_Count := N.Element_Count'Value (Rest (Rest'First .. Second - 1));
                        Expected : constant Long_Float := Long_Float'Value (Rest (Second + 1 .. Rest'Last));
                     begin
                        Worst := Long_Float'Max (Worst, abs (Long_Float (Mel (M * Frames + Fr)) - Expected));
                     end;
                  end;
               end if;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      Ts.Free (Samples);
      Ts.Free (Mel);
      Assert (Worst < 1.0E-4, Name & "'s spectrogram is off the reference's by" & Worst'Image);
   end Check_Spectrogram;

   procedure Spectrograms_Are_The_Reference
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Check_Spectrogram ("jfk");
      Check_Spectrogram ("da-short");
   end Spectrograms_Are_The_Reference;

   --  Silence is the floor everywhere, (log10 1e-10 + 4) / 4; and a
   --  recording shorter than a window is a spectrogram once padded.
   procedure Spectrogram_Of_Silence
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Quiet  : constant N.Real_Array (0 .. 15_999) := [others => 0.0];
      Mel    : Ts.Real_Array_Access;
      Status : E.Error_Info;
   begin
      S.Log_Mel (Quiet, 80, 0, Mel, Status);
      Assert (E.Is_Ok (Status), "silence was refused");
      Assert (Mel.all'Length = 80 * 100, "a second is" & Mel.all'Length'Image & " values");
      for V of Mel.all loop
         Assert (V = -1.5, "silence has a value of" & V'Image);
      end loop;
      Ts.Free (Mel);

      S.Log_Mel (Quiet (0 .. 99), 80, 0, Mel, Status);
      Assert (Status.Code = E.IO_Audio_Unreadable, "a hundred samples alone were not refused");
      S.Log_Mel (Quiet (0 .. 99), 80, 480_000, Mel, Status);
      Assert (E.Is_Ok (Status) and then Mel.all'Length = 80 * 3_000,
              "a hundred samples padded are not three thousand frames");
      Ts.Free (Mel);
   end Spectrogram_Of_Silence;

   --------------
   -- Decoding --
   --------------

   package D renames Model_Runner.Whisper.Decoding;

   subtype Token_Id is Model_Runner.Tokenizer.Token_Id;

   use type Token_Id;

   --  A vocabulary of thirty: text 0 .. 9, the end 10, no-times 11, times
   --  12 .. 29.
   Small_Rules : constant D.Rules :=
     (End_Of_Text => 10, No_Timestamps => 11, Timestamp_Begin => 12, Vocabulary => 30,
      Suppressed => [1 => 3, others => 0], Suppressed_Count => 1,
      Begin_Suppressed => [1 => 2, 2 => 10, others => 0], Begin_Suppressed_Count => 2,
      Timestamps => True, Max_Initial_Timestamp => 4);

   function Flat return N.Real_Array is [0 .. 29 => 0.0];

   function Allowed (Logits : N.Real_Array; Token : Natural) return Boolean is
     (Logits (N.Element_Count (Token)) > N.Real'First);

   function Verdict (Logits : N.Real_Array; Token : Natural) return String is
     (if Allowed (Logits, Token) then " is allowed" else " is not");

   --  The reference's rules, step by step.
   procedure Decoding_Rules_Are_The_Reference
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Logits : N.Real_Array (0 .. 29);
   begin
      --  The first step: a time no later than the fourth, nothing else.
      Logits := Flat;
      D.Apply (Small_Rules, [], Logits);
      for Id in 0 .. 29 loop
         Assert (Allowed (Logits, Id) = (Id in 12 .. 16), "at the first step, token" & Id'Image
                 & Verdict (Logits, Id));
      end loop;

      --  After a time and text: text, the end, or a later time -- the text
      --  likelier than every time together, which would otherwise win.
      Logits := Flat;
      Logits (0 .. 10) := [others => 5.0];
      D.Apply (Small_Rules, [Token_Id'(15), 4], Logits);
      for Id in 0 .. 29 loop
         Assert (Allowed (Logits, Id) = (Id in 0 .. 2 | 4 .. 9 | 10 | 16 .. 29),
                 "after a time and text, token" & Id'Image & Verdict (Logits, Id));
      end loop;

      --  After text and a time that closes: the end, or a time no earlier --
      --  the end likelier than every time together.
      Logits := Flat;
      Logits (10) := 5.0;
      D.Apply (Small_Rules, [Token_Id'(15), 4, 18], Logits);
      for Id in 0 .. 29 loop
         Assert (Allowed (Logits, Id) = (Id = 10 or else Id in 18 .. 29),
                 "after a closing time, token" & Id'Image & Verdict (Logits, Id));
      end loop;

      --  After two times: text, or the end; no time.
      Logits := Flat;
      Logits (5) := 3.0;
      D.Apply (Small_Rules, [Token_Id'(15), 4, 18, 18], Logits);
      for Id in 0 .. 29 loop
         Assert (Allowed (Logits, Id) = (Id in 0 .. 2 | 4 .. 10),
                 "after a pair of times, token" & Id'Image & Verdict (Logits, Id));
      end loop;

      --  Times together likelier than the likeliest text: a time.
      Logits := Flat;
      Logits (4) := 1.0;
      D.Apply (Small_Rules, [Token_Id'(15), 4], Logits);
      Assert (not Allowed (Logits, 4) and then Allowed (Logits, 20),
              "fourteen times at nought were not preferred to one text token at one");

      --  Without times: only the two suppressions.
      Logits := Flat;
      D.Apply ((Small_Rules with delta Timestamps => False), [], Logits);
      for Id in 0 .. 29 loop
         Assert (Allowed (Logits, Id) = (Id not in 2 | 3 | 10), "without times, token" & Id'Image
                 & Verdict (Logits, Id));
      end loop;
      Logits := Flat;
      D.Apply ((Small_Rules with delta Timestamps => False), [Token_Id'(4)], Logits);
      Assert (Allowed (Logits, 2) and then Allowed (Logits, 10) and then not Allowed (Logits, 3),
              "a blank and the end are refused past the first step");
   end Decoding_Rules_Are_The_Reference;

   --  Greedy is the first of the largest; a log probability is the
   --  log-softmax, minus infinity a token never said; repeated text
   --  compresses.
   procedure Picking_And_Measuring
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Logits : constant N.Real_Array := [0 => 1.0, 1 => 3.0, 2 => 3.0, 3 => N.Real'First];
      Sum    : constant Long_Float := F.Exp (1.0) + 2.0 * F.Exp (3.0);
   begin
      Assert (D.Pick (Logits) = 1, "the first of two largest was not picked");
      Assert (abs (Long_Float (D.Log_Probability (Logits, 1)) - (3.0 - F.Log (Sum))) < 1.0E-12,
              "a log probability is not the log-softmax");
      Assert (D.Probability (Logits, 3) = 0.0, "a suppressed token has a probability");
      Assert (D.Compression_Ratio ("") = 0.0, "an empty text has a ratio");
      Assert (D.Compression_Ratio ("the the the the the the the the the the the the the the the the the the") > 2.4,
              "a text repeating itself does not compress past the threshold");
      Assert (D.Compression_Ratio ("And so my fellow Americans, ask not") < 1.5,
              "a sentence compresses as though it repeated itself");
   end Picking_And_Measuring;

   --  A draw is the reference's Categorical over the logits and a
   --  temperature: the first token whose running probability passes it,
   --  never one suppressed; the stream is the same for the same seed and
   --  stays in [0, 1).
   procedure Sampling_At_A_Temperature
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      --  One in four, three in four at a temperature of one.
      Logits : constant N.Real_Array := [0 => 0.0, 1 => N.Real (F.Log (3.0)), 2 => N.Real'First];
      One, Two : D.Stream := D.Seeded (42);
      A, B : N.Wide_Real;
      Ones : Natural := 0;
   begin
      Assert (D.Sample (Logits, 1.0, 0.2) = 0, "a draw of 0.2 is not the first quarter's");
      Assert (D.Sample (Logits, 1.0, 0.3) = 1, "a draw of 0.3 is not the rest's");
      Assert (D.Sample (Logits, 1.0, 0.999) = 1, "the last draw fell to a suppressed token");
      --  Hot, the two even; cold, the likelier alone.
      Assert (D.Sample (Logits, 100.0, 0.49) = 0, "a hot draw of 0.49 is not the first half's");
      Assert (D.Sample (Logits, 0.01, 0.001) = 1, "a cold draw is not the likelier");
      for I in 1 .. 1_000 loop
         D.Next (One, A);
         D.Next (Two, B);
         Assert (A = B and then A >= 0.0 and then A < 1.0, "the stream is not the same, or not in [0, 1)");
         if D.Sample (Logits, 1.0, A) = 1 then
            Ones := Ones + 1;
         end if;
      end loop;
      Assert (Ones in 700 .. 800, "three in four draws came out" & Ones'Image & " in a thousand");
   end Sampling_At_A_Temperature;

   -----------
   -- Model --
   -----------

   package W renames Model_Runner.Whisper;

   Fixture_Path : constant String := "obj/whisper-fixture.gguf";

   --  A file that is not the profile's is refused by name, and leaves no
   --  model behind.
   procedure Whisper_Files_Are_Held_To_The_Profile
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Whisper_Fixture.Flaw;
      Model  : W.Model;
      Status : E.Error_Info;
      Expected : constant array (Whisper_Fixture.Flaw) of E.Error_Code :=
        [Whisper_Fixture.None => E.No_Error,
         Whisper_Fixture.Other_Architecture => E.Arch_Unsupported,
         Whisper_Fixture.Missing_Tensor => E.Arch_Missing_Tensor,
         Whisper_Fixture.Misshapen_Tensor => E.Arch_Invalid_Tensor_Shape,
         Whisper_Fixture.Vocabulary_Mismatch => E.Arch_Vocabulary_Mismatch,
         others => E.GGUF_Metadata_Out_Of_Range];
   begin
      for Defect in Whisper_Fixture.Flaw loop
         Whisper_Fixture.Write (Fixture_Path, Defect);
         W.Prepare (Model, Fixture_Path, Status);
         Assert (Status.Code = Expected (Defect),
                 Defect'Image & " gave " & Status.Code'Image & " for " & Expected (Defect)'Image);
         Assert (W.Is_Ready (Model) = (Defect = Whisper_Fixture.None), Defect'Image & " left the model ready or not");
         W.Close (Model, Status);
      end loop;
      W.Prepare (Model, "obj/no-such-whisper.gguf", Status);
      Assert (E.Is_Error (Status) and then not W.Is_Ready (Model), "a missing file was read");
   end Whisper_Files_Are_Held_To_The_Profile;

   --  A model does not close under a session; a session does not open on
   --  a model not ready; a session closed twice is closed.
   procedure Whisper_Lifecycle
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Model   : aliased W.Model;
      Session : W.Session;
      Status  : E.Error_Info;
      Logits  : N.Real_Array (0 .. 1_767);
   begin
      W.Open (Session, Model'Access, null, Status);
      Assert (Status.Code = E.Lifecycle_Model_Not_Ready, "a session opened on no model");
      declare
         Heard : W.Transcript;
         Quiet : constant N.Real_Array (0 .. 15_999) := [others => 0.0];
      begin
         W.Transcribe (Session, Quiet, (others => <>), Heard, Status);
         Assert (Status.Code = E.Lifecycle_Session_Closed, "a closed session heard");
      end;
      Whisper_Fixture.Write (Fixture_Path);
      W.Prepare (Model, Fixture_Path, Status);
      Assert (E.Is_Ok (Status), "the fixture was refused: " & Status.Code'Image);
      Assert (W.Is_Multilingual (Model) and then W.Language_Count (Model) = 2 and then W.Language_Code (Model, 2) = "da"
              and then W.Knows_Language (Model, "en") and then not W.Knows_Language (Model, "fr"),
              "the languages were not read");
      W.Open (Session, Model'Access, null, Status);
      Assert (E.Is_Ok (Status) and then W.Sessions_Open (Model) = 1, "a session did not open");
      W.Decode (Session, [1 => 257], Logits, Status);
      Assert (Status.Code = E.Lifecycle_Invalid_State, "the decoder ran with nothing heard");
      W.Close (Model, Status);
      Assert (Status.Code = E.Lifecycle_Session_Active and then W.Is_Ready (Model),
              "the model closed under its session");
      W.Close (Session);
      W.Close (Session);
      Assert (W.Sessions_Open (Model) = 0, "a session closed twice was counted twice");
      W.Close (Model, Status);
      Assert (E.Is_Ok (Status) and then not W.Is_Ready (Model), "the model did not close");
   end Whisper_Lifecycle;

   --  The fixture hears a second of noise in Danish, and in a language
   --  it does not have refuses; past its context it refuses; a cancel
   --  stops it.
   procedure Whisper_Transcribes_And_Refuses
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use Ada.Strings.Unbounded;
      Model    : aliased W.Model;
      Session  : W.Session;
      Status   : E.Error_Info;
      Heard    : W.Transcript;
      Settings : W.Options;
      Sound    : N.Real_Array (0 .. 15_999);
      Mel      : Ts.Real_Array_Access := new N.Real_Array'(0 .. 80 * 3_000 - 1 => -0.5);
      Logits   : N.Real_Array (0 .. 1_767);
      Stop     : aliased Model_Runner.Cancellation.Token;
   begin
      for I in Sound'Range loop
         Sound (I) := N.Real (0.3 * Noise (Natural (I)));
      end loop;
      Whisper_Fixture.Write (Fixture_Path);
      W.Prepare (Model, Fixture_Path, Status);
      W.Open (Session, Model'Access, null, Status);
      Assert (E.Is_Ok (Status), "a session did not open");

      W.Encode (Session, Mel.all, Status);
      Assert (E.Is_Ok (Status), "the encoder failed: " & Status.Code'Image);
      W.Decode (Session, [257, 259, 261], Logits, Status);
      Assert (E.Is_Ok (Status), "the decoder failed: " & Status.Code'Image);
      for V of Logits loop
         Assert (V = V and then abs V < 1.0E6, "a logit is not a number");
      end loop;
      W.Decode (Session, [1 .. 17 => 257], Logits, Status);
      Assert (Status.Code = E.Generation_Prompt_Too_Long, "seventeen tokens fit a context of sixteen");
      W.Encode (Session, Mel (0 .. 99), Status);
      Ts.Free (Mel);
      Assert (Status.Code = E.Tensor_Shape_Mismatch, "a short spectrogram was encoded");

      Settings.Language := To_Unbounded_String ("da");
      W.Transcribe (Session, Sound, Settings, Heard, Status);
      Assert (E.Is_Ok (Status), "a second of noise was not heard: " & Status.Code'Image);
      Assert (To_String (Heard.Language) = "da", "the language given was not kept");
      Assert (Heard.Figures.Windows = 1, "a second was" & Heard.Figures.Windows'Image & " windows");
      Assert (not Heard.Segments.Is_Empty, "a window gave no segment");

      Settings.Language := Null_Unbounded_String;
      W.Transcribe (Session, Sound, Settings, Heard, Status);
      Assert (E.Is_Ok (Status) and then To_String (Heard.Language) in "en" | "da", "no language was detected");
      Settings.Detect_From_Window := True;
      W.Transcribe (Session, Sound, Settings, Heard, Status);
      Assert (E.Is_Ok (Status) and then To_String (Heard.Language) in "en" | "da",
              "no language was read off the window");
      Settings.Detect_From_Window := False;

      --  The fixture is noise: unlikely at every temperature, so every one
      --  is tried and the last kept, marked; and asked to translate, it
      --  does, the same way.
      Settings.Language := To_Unbounded_String ("da");
      Settings.Translate := True;
      W.Transcribe (Session, Sound, Settings, Heard, Status);
      Assert (E.Is_Ok (Status), "translating failed: " & Status.Code'Image);
      for Piece of Heard.Segments loop
         Assert (Piece.Silent or else Piece.Temperature in 0.0 | 0.2 | 0.4 | 0.6 | 0.8 | 1.0,
                 "a window was decoded at" & Piece.Temperature'Image);
         Assert (Piece.Silent or else Piece.Temperature = 0.0 or else Piece.Uncertain or else
                 Piece.Average_Log_Probability >= -1.0, "a window retried and kept was not marked");
      end loop;
      Settings.Translate := False;
      Settings.Temperature_Count := 1;
      Settings.Word_Timestamps := True;
      W.Transcribe (Session, Sound, Settings, Heard, Status);
      Assert (E.Is_Ok (Status), "word timing failed: " & Status.Code'Image);
      for Piece of Heard.Segments loop
         for Word of Piece.Words loop
            Assert (Word.Start_Seconds <= Word.End_Seconds and then Word.Start_Seconds >= 0.0,
                    "a word ends before it starts");
         end loop;
      end loop;
      Settings.Word_Timestamps := False;
      W.Transcribe (Session, Sound, Settings, Heard, Status);
      for Piece of Heard.Segments loop
         Assert (Piece.Temperature = 0.0, "one temperature of nought sampled");
      end loop;

      Settings.Language := To_Unbounded_String ("fr");
      W.Transcribe (Session, Sound, Settings, Heard, Status);
      Assert (Status.Code = E.Generation_Invalid_Request, "a language the model has not was taken");

      Settings.Language := To_Unbounded_String ("da");
      Stop.Request;
      W.Transcribe (Session, Sound, Settings, Heard, Status, Cancel => Stop'Unchecked_Access);
      Assert (Status.Code = E.Generation_Cancelled, "a cancel did not stop it: " & Status.Code'Image);
      W.Close (Session);
      W.Close (Model, Status);
   end Whisper_Transcribes_And_Refuses;

   ------------
   -- Timing --
   ------------

   --  The warp is the reference's: the cheapest path, its ties broken as
   --  dtw_cpu breaks them; the median is over seven, the ends reflected.
   procedure Word_Timing_Arithmetic
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Tm renames Model_Runner.Whisper.Timing;
      use type Tm.Index_List;
      --  Three tokens over six frames, each cheapest on two of its own.
      Cost : constant Tm.Cost_Matrix (0 .. 2, 0 .. 5) :=
        [[-1.0, -1.0, 0.0, 0.0, 0.0, 0.0],
         [0.0, 0.0, -1.0, -1.0, 0.0, 0.0],
         [0.0, 0.0, 0.0, 0.0, -1.0, -1.0]];
      Rows_Of, Columns_Of : Tm.Index_List (1 .. 9);
      Steps : Natural;
      Line  : Tm.Cost_Matrix (0 .. 0, 0 .. 8) := [[5.0, 1.0, 9.0, 2.0, 7.0, 3.0, 8.0, 4.0, 6.0]];
   begin
      Tm.Warp (Cost, Rows_Of, Columns_Of, Steps);
      --  The reference's dtw on the same cost: down where a tie leaves it.
      Assert (Steps = 8, "the path took" & Steps'Image & " steps");
      Assert (Rows_Of (1 .. 8) = [0, 0, 1, 1, 1, 2, 2, 2] and then Columns_Of (1 .. 8) = [0, 1, 1, 2, 3, 3, 4, 5],
              "the path is not the reference's");
      Tm.Median_Filter (Line);
      --  Reflected: 2 9 1 5 1 9 2 7 3 8 4 6 4 8 3 ...
      Assert (Line (0, 0) = 2.0 and then Line (0, 4) = 4.0 and then Line (0, 8) = 4.0,
              "the median is not the reference's: " & Line (0, 0)'Image & Line (0, 4)'Image & Line (0, 8)'Image);
   end Word_Timing_Arithmetic;

   ---------------
   -- Insertion --
   ---------------

   --  What is heard goes in at the cursor as the editor's policy says.
   procedure Spoken_Text_Goes_In_Where_The_Cursor_Is
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use Ada.Strings.Unbounded;
      package Ch renames Model_Runner.CLI.Choosers;

      procedure Check (Before : String; At_Cursor : Natural; Spoken : String; After : String;
                       Cursor_After : Natural; Most : Natural := 1_000) is
         Line   : Unbounded_String := To_Unbounded_String (Before);
         Cursor : Natural := At_Cursor;
         Done   : Boolean;
      begin
         Ch.Insert_Spoken (Line, Cursor, Spoken, Most, Done);
         Assert (To_String (Line) = After, "[" & Before & "] with [" & Spoken & "] became [" & To_String (Line) & "]");
         Assert (Done = (After /= Before), "[" & Spoken & "] said the wrong thing of whether it went in");
         Assert (Cursor = Cursor_After, "the cursor stood at" & Cursor'Image & " after [" & Spoken & "]");
      end Check;
   begin
      Check ("", 0, " Hello there.", "Hello there.", 12);
      Check ("Please summarise:", 17, " And so my fellow", "Please summarise: And so my fellow", 34);
      Check ("ab ", 3, "cd", "ab cd", 5);
      Check ("start end", 6, "middle", "start middle end", 12);
      Check ("start ,end", 6, "middle", "start middle,end", 12);
      Check ("", 0, "line one" & ASCII.LF & "line" & ASCII.HT & "two", "line one line two", 17);
      Check ("", 0, " /reset", " /reset", 7);
      Check ("x", 1, "   ", "x", 1);
      Check ("x", 1, [Character'Val (16#C3#)], "x", 1);
      Check ("x", 1, "too long", "x", 1, Most => 5);
      --  UTF-8 written out: an e with an acute, and an a with a ring.
      declare
         E_Acute : constant String := [Character'Val (16#C3#), Character'Val (16#A9#)];
         A_Ring  : constant String := [Character'Val (16#C3#), Character'Val (16#A5#)];
      begin
         Check (E_Acute, 2, "s" & A_Ring, E_Acute & " s" & A_Ring, 6);
         Check ("x" & E_Acute, 1, "y", "x y " & E_Acute, 3);
      end;
   end Spoken_Text_Goes_In_Where_The_Cursor_Is;

   -----------------
   -- Recognizers --
   -----------------

   --  Speech with no model is off and says so; one whose model and
   --  microphone are not there fails, says why, and is ready to be asked
   --  again; a busy one refuses a second recording; and it stops.
   procedure Recognizer_Lifecycle
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use Ada.Strings.Unbounded;
      package Sp renames Model_Runner.Speech;
      use type Sp.State;
      use type Sp.Recognizer_Access;

      --  A second of noise, played in place of the microphone: no test
      --  opens one.
      Sound : aliased constant N.Real_Array :=
        [for I in N.Element_Count range 0 .. 15_999 => N.Real (0.2 * Noise (Natural (I)))];

      Off, Absent, Heard_Here : Sp.Recognizer_Access;
      Status : E.Error_Info;
      Text   : Unbounded_String;
      Limit  : Boolean;

      procedure Wait (Until_True : access function return Boolean) is
      begin
         for Tenth in 1 .. 200 loop
            exit when Until_True.all;
            delay 0.05;
         end loop;
      end Wait;

      function Absent_Done return Boolean is (Sp.Has_Result (Absent.all));
      function Ended return Boolean is (Sp.Recording_Ended (Heard_Here.all));
      function Heard_Done return Boolean is (Sp.Has_Result (Heard_Here.all));
      function Is_Ready return Boolean is (Sp.Current (Heard_Here.all) = Sp.Ready);
      function Is_Unloaded return Boolean is (Sp.Current (Heard_Here.all) = Sp.Unloaded);
   begin
      Whisper_Fixture.Write (Fixture_Path);
      Off := Sp.Create ((others => <>));
      Absent := Sp.Create ((Model_Path => To_Unbounded_String ("obj/no-such-whisper.gguf"),
                            Played => Sound'Unchecked_Access, others => <>));
      Heard_Here := Sp.Create ((Model_Path => To_Unbounded_String (Fixture_Path), Workers => 1,
                                Played => Sound'Unchecked_Access, others => <>));

      Assert (Sp.Current (Off.all) = Sp.Disabled, "speech with no model is not off");
      Sp.Start (Off.all, Status);
      Assert (Status.Code = E.Lifecycle_Speech_Disabled, "speech with no model began: " & Status.Code'Image);

      --  A model that is not there: refused when heard, and asked again.
      Assert (Sp.Current (Absent.all) = Sp.Unloaded, "a named model is not unloaded before use");
      Sp.Start (Absent.all, Status);
      Assert (E.Is_Ok (Status) and then Sp.Current (Absent.all) = Sp.Recording, "a recording did not begin");
      Sp.Start (Absent.all, Status);
      Assert (Status.Code = E.Lifecycle_Invalid_State, "a second recording began beside the first");
      Sp.Finish (Absent.all, Status);
      Assert (E.Is_Ok (Status), "a recording did not finish");
      Wait (Absent_Done'Access);
      Assert (Sp.Has_Result (Absent.all), "nothing came back in ten seconds");
      Sp.Take (Absent.all, Text, Status, Limit);
      Assert (E.Is_Error (Status) and then Length (Text) = 0,
              "a model not there was heard with: " & Status.Code'Image);
      Assert (Sp.Current (Absent.all) not in Sp.Recording | Sp.Transcribing,
              "a failure left it " & Sp.Image (Sp.Current (Absent.all)));
      Sp.Start (Absent.all, Status);
      Assert (E.Is_Ok (Status), "it could not be asked again after failing");
      Sp.Cancel (Absent.all);
      Assert (Sp.Current (Absent.all) not in Sp.Recording, "a cancel left it recording");

      --  A model that is there: the second played, heard, the model kept,
      --  then given back on asking.
      Sp.Start (Heard_Here.all, Status);
      Assert (E.Is_Ok (Status), "a recording did not begin");
      Wait (Ended'Access);
      Assert (Sp.Recording_Ended (Heard_Here.all), "the played second did not end the recording");
      Assert (Sp.Recorded_Seconds (Heard_Here.all) = 1.0,
              "a second was recorded as" & Sp.Recorded_Seconds (Heard_Here.all)'Image);
      Sp.Finish (Heard_Here.all, Status);
      Wait (Heard_Done'Access);
      Sp.Take (Heard_Here.all, Text, Status, Limit);
      Assert (E.Is_Ok (Status) and then not Limit, "the played second was not heard: " & Status.Code'Image);
      Wait (Is_Ready'Access);
      Assert (Sp.Current (Heard_Here.all) = Sp.Ready,
              "the model was not kept: " & Sp.Image (Sp.Current (Heard_Here.all)));
      Sp.Unload (Heard_Here.all, Status);
      Assert (E.Is_Ok (Status), "an idle model was not given back");
      Wait (Is_Unloaded'Access);
      Assert (Sp.Current (Heard_Here.all) = Sp.Unloaded, "the model was not given back");

      --  A source the sound server has not: refused by name, and no
      --  microphone opened in its place -- hostkit asks the server first.
      declare
         Deaf : Sp.Recognizer_Access :=
           Sp.Create ((Model_Path => To_Unbounded_String (Fixture_Path), Workers => 1,
                       Source => To_Unbounded_String ("model-runner-test-no-such-source"), others => <>));
         function Deaf_Done return Boolean is (Sp.Has_Result (Deaf.all));
      begin
         Sp.Start (Deaf.all, Status);
         Sp.Finish (Deaf.all, Status);
         Wait (Deaf_Done'Access);
         Sp.Take (Deaf.all, Text, Status, Limit);
         Sp.Shutdown (Deaf);
         Assert (Status.Code = E.IO_Microphone_Unavailable,
                 "a source the server has not was not refused by name: " & Status.Code'Image);
      end;

      Sp.Shutdown (Off);
      Sp.Shutdown (Absent);
      Sp.Shutdown (Heard_Here);
      Assert (Off = null and then Absent = null and then Heard_Here = null,
              "a recognizer shut down was not given back");
      Sp.Shutdown (Absent);
   exception
      --  A recognizer's tasks outlive the test unless it is shut down.
      when others =>
         Sp.Shutdown (Off);
         Sp.Shutdown (Absent);
         Sp.Shutdown (Heard_Here);
         raise;
   end Recognizer_Lifecycle;

   --  The session's adapter: with no speech model it is off, says so when
   --  asked to record, and has nothing under way.
   procedure Speech_Input_Without_A_Model
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use Ada.Strings.Unbounded;
      Input  : Model_Runner.CLI.Speech_Input.Input;
      Asked  : Model_Runner.CLI.Options.Command;
      Status : E.Error_Info;
      Text   : Unbounded_String;
      Limit  : Boolean;
   begin
      Model_Runner.CLI.Speech_Input.Open (Input, Asked);
      Assert (not Model_Runner.CLI.Speech_Input.Is_Enabled (Input), "speech is on with no model named");
      Input.Begin_Dictation (Status);
      Assert (Status.Code = E.Lifecycle_Speech_Disabled, "a recording began with no model");
      Assert (not Input.Ended_Itself and then Input.Is_Done and then Input.Seconds = 0,
              "speech with no model has something under way");
      Input.Take (Text, Status, Limit);
      Assert (Length (Text) = 0 and then Status.Code = E.Lifecycle_Speech_Disabled, "speech with no model heard");
      Model_Runner.CLI.Speech_Input.Close (Input);
   end Speech_Input_Without_A_Model;

   --  The speech model is refused, never the conversation's shrunk, where
   --  the two do not fit.
   procedure Speech_Is_Admitted_By_Memory
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Interfaces.Unsigned_64;
      Status : E.Error_Info;
      Gigabyte : constant Interfaces.Unsigned_64 := 1024 * 1024 * 1024;
   begin
      Model_Runner.Speech.Admit (Gigabyte, 4 * Gigabyte, Status);
      Assert (E.Is_Ok (Status), "a gigabyte did not fit in four");
      Model_Runner.Speech.Admit (Gigabyte, Gigabyte + 1, Status);
      Assert (Status.Code = E.Memory_Limit_Exceeded, "a gigabyte fit with no room left over");
      Model_Runner.Speech.Admit (4 * Gigabyte, Gigabyte, Status);
      Assert (Status.Code = E.Memory_Limit_Exceeded, "four gigabytes fit in one");
   end Speech_Is_Admitted_By_Memory;

   ------------------
   -- Coexistence --
   ------------------

   --  A conversation's session gives the same logits whether or not a
   --  Whisper model was read, heard with, failed and closed beside it:
   --  the two share nothing that either writes.
   procedure Speech_Leaves_The_Conversation_Alone
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package L renames Model_Runner.Llama;
      package Containers renames Model_Runner.GGUF.Containers;
      use type N.Real_Array;
      Image : Model_Runner.Bytes.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);
      declare
         Held    : aliased constant Model_Runner.Bytes.Byte_Array := Image.all;
         Source  : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed  : Containers.Container;
         Model   : aliased L.Model;
         Alone, Beside : L.Session;
         Status  : E.Error_Info;
         Vocabulary : constant N.Element_Count := N.Element_Count (Tiny_Model.Vocabulary);
         First, Second : N.Real_Array (0 .. Vocabulary - 1);
         Whisper : aliased W.Model;
         Hearing : W.Session;
         Heard   : W.Transcript;
         Sound   : constant N.Real_Array (0 .. 7_999) := [others => 0.01];
      begin
         Containers.Reader.Parse (Parsed, Source, Status => Status);
         L.Prepare (Model, Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the tiny model did not prepare");
         L.Open (Alone, Model, Status => Status);
         L.Open (Beside, Model, Status => Status);
         for Token of Model_Runner.Tokenizer.Token_Array'[1, 4, 5, 6] loop
            L.Evaluate (Alone, Model, Token, First, Status => Status);
            L.Evaluate (Beside, Model, Token, Second, Status => Status);
         end loop;

         --  Whisper beside it: refused, read, heard with, closed.
         W.Prepare (Whisper, "obj/no-such-whisper.gguf", Status);
         Assert (E.Is_Error (Status), "a missing speech model was read");
         Whisper_Fixture.Write (Fixture_Path);
         W.Prepare (Whisper, Fixture_Path, Status);
         W.Open (Hearing, Whisper'Access, null, Status);
         W.Transcribe (Hearing, Sound, (others => <>), Heard, Status);
         Assert (E.Is_Ok (Status), "the speech model did not hear beside the conversation");
         W.Close (Hearing);
         W.Close (Whisper, Status);

         L.Evaluate (Alone, Model, 7, First, Status => Status);
         L.Evaluate (Beside, Model, 7, Second, Status => Status);
         Assert (E.Is_Ok (Status) and then L.Is_Ready (Model), "the conversation's model is not as it was");
         Assert (First = Second, "the conversation's logits moved while speech was heard beside it");
         L.Close (Alone);
         L.Close (Beside);
         L.Close (Model, Status);
      end;
      Model_Runner.Bytes.Free (Image);
   end Speech_Leaves_The_Conversation_Alone;

   --  The session, run on a terminal as a person runs it, the recording a
   --  WAV file played as its source: dictation after typed text keeps the
   --  text and the keys pressed while it was heard land after it; Escape
   --  drops a recording, the line as typed; Ctrl-_ takes a transcript out
   --  again. What was entered is read back from the history it keeps.
   procedure Dictation_In_A_Session
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use type Hostkit.Descriptors.Descriptor;
      use type Hostkit.Spawn.Spawn_Outcome;
      use type Ada.Streams.Stream_Element_Offset;

      Model   : constant String := Ada.Directories.Full_Name ("obj/dictation-model.gguf");
      Speech  : constant String := Ada.Directories.Full_Name ("obj/dictation-whisper.gguf");
      Sound   : constant String := Ada.Directories.Full_Name (Fixtures & "jfk.wav");
      Project : constant String := Ada.Directories.Full_Name ("obj/dictation-project");
      History : constant String := Project & "/.model_runner/runtime/prompt-history";
      Plain   : constant String := "../bin/model_runner";
      Binary  : constant String :=
        Ada.Directories.Full_Name (if Ada.Directories.Exists (Plain) then Plain else Plain & ".exe");

      Pair    : Hostkit.Pty.Pair;
      Options : Hostkit.Spawn.Options;
      Child   : Hostkit.Spawn.Process_Handle;
      Result  : Hostkit.Spawn.Status;
      Buffer  : Ada.Streams.Stream_Element_Array (1 .. 4096);
      Last    : Ada.Streams.Stream_Element_Offset;

      procedure Keep_Variable (Name, Value : String) is
      begin
         if Name /= "TERM" then
            Options.Environment.Append (Ada.Strings.Unbounded.To_Unbounded_String (Name & "=" & Value));
         end if;
      end Keep_Variable;

      --  What the session wrote, kept to be shown where a check fails.
      Screen : Ada.Strings.Unbounded.Unbounded_String;

      --  Read what the session writes for Quiet milliseconds -- not until it
      --  is quiet: while it records it redraws its status five times a
      --  second, and a wait for quiet would wait out the recording.
      procedure Drain (Quiet : Integer := 1500) is
         use type Ada.Calendar.Time;
         Until_Then : constant Ada.Calendar.Time := Ada.Calendar.Clock + Duration (Quiet) / 1000.0;
      begin
         while Ada.Calendar.Clock < Until_Then
           and then Hostkit.Descriptors.Wait_Readable
                      (Pair.From_Child, Integer'Max (1, Integer ((Until_Then - Ada.Calendar.Clock) * 1000.0)))
         loop
            exit when Hostkit.Descriptors."/=" (Hostkit.Descriptors.Read (Pair.From_Child, Buffer, Last),
                                                Hostkit.Descriptors.Transfer_Ok)
              or else Last < Buffer'First;
            for B of Buffer (Buffer'First .. Last) loop
               Ada.Strings.Unbounded.Append (Screen, Character'Val (B));
            end loop;
         end loop;
      end Drain;

      function Tail return String is
         Whole : constant String := Ada.Strings.Unbounded.To_String (Screen);
      begin
         return Whole (Integer'Max (Whole'First, Whole'Last - 1_500) .. Whole'Last);
      end Tail;

      procedure Send (Text : String; Quiet : Integer := 20) is
         Keys : Ada.Streams.Stream_Element_Array (1 .. Text'Length);
         Used : Ada.Streams.Stream_Element_Offset := 0;
      begin
         for C of Text loop
            Used := Used + 1;
            Keys (Used) := Character'Pos (C);
         end loop;
         Assert (Hostkit.Descriptors."="
                   (Hostkit.Descriptors.Write (Pair.To_Child, Keys (1 .. Used), Last), Hostkit.Descriptors.Transfer_Ok),
                 "a key was not sent");
         Drain (Quiet);
      end Send;

      Shortcut : constant Character := Character'Val (7);
      Undo     : constant Character := Character'Val (16#1F#);
      Held     : Ada.Text_IO.File_Type;
      Entered  : array (1 .. 3) of Ada.Strings.Unbounded.Unbounded_String;
      Count    : Natural := 0;
   begin
      if not Hostkit.Pty.Is_Supported or else not Hostkit.Pty.Open (Pair)
        or else Pair.Device = Hostkit.Descriptors.Invalid
      then
         Ada.Text_IO.Put_Line ("note: no pseudo-terminal here; not checked");
         return;
      end if;
      Tiny_Model.Write (Model, Room => 64);
      Whisper_Fixture.Write (Speech);
      if Ada.Directories.Exists (Project) then
         Ada.Directories.Delete_Tree (Project);
      end if;
      Ada.Directories.Create_Path (Project & "/.model_runner/runtime");

      Ada.Environment_Variables.Iterate (Keep_Variable'Access);
      Options.Environment.Append (Ada.Strings.Unbounded.To_Unbounded_String ("TERM=xterm"));
      Options.Replace_Environment := True;
      Options.Working_Directory := Ada.Strings.Unbounded.To_Unbounded_String (Project);
      Assert (Hostkit.Pty.Set_Size (Pair, (Rows => 24, Columns => 200)) and then Hostkit.Pty.Attach (Pair, Options),
              "the pseudo-terminal was not made ready");
      declare
         Words : Hostkit.String_Vectors.Vector;
         procedure Word (Text : String) is
         begin
            Words.Append (Ada.Strings.Unbounded.To_Unbounded_String (Text));
         end Word;
      begin
         Word (Model);
         Word ("--backend");
         Word ("cpu");
         Word ("--max-tokens");
         Word ("1");
         Word ("--speech-model");
         Word (Speech);
         Word ("--speech-device");
         Word ("file:" & Sound);
         Word ("--speech-language");
         Word ("en");
         Assert (Hostkit.Spawn.Start (Binary, Words, Options, Child) = Hostkit.Spawn.Spawn_Ok,
                 "the session did not start");
      end;
      Hostkit.Pty.Close_Device (Pair);
      Drain (5000);

      --  Typed, dictated, a key pressed while it is heard, entered.
      Send ("first" & Shortcut, Quiet => 1000);
      Send ([1 => Shortcut] & "X", Quiet => 8000);
      Send ([1 => ASCII.CR], Quiet => 1500);
      --  Typed, a recording dropped, entered.
      Send ("second" & Shortcut, Quiet => 300);
      Send ([1 => ASCII.ESC], Quiet => 2000);
      Send ([1 => ASCII.CR], Quiet => 1500);
      --  Typed, dictated, taken out again, entered.
      Send ("third" & Shortcut, Quiet => 1000);
      Send ([1 => Shortcut], Quiet => 8000);
      Send ([Undo, ASCII.CR], Quiet => 1500);
      --  The turn sent, and out.
      Send ([1 => ASCII.CR], Quiet => 5000);
      Send ("/exit" & ASCII.CR, Quiet => 3000);
      Assert (Hostkit.Spawn.Wait (Child, Hostkit.Spawn.Wait_Block, Result), "the session was not waited for");
      Hostkit.Pty.Close (Pair);

      Ada.Text_IO.Open (Held, Ada.Text_IO.In_File, History);
      while not Ada.Text_IO.End_Of_File (Held) and then Count < Entered'Last loop
         Count := Count + 1;
         Entered (Count) := Ada.Strings.Unbounded.To_Unbounded_String (Ada.Text_IO.Get_Line (Held));
      end loop;
      Ada.Text_IO.Close (Held);
      Assert (Count = 3, "the session entered" & Count'Image & " lines");
      declare
         use Ada.Strings.Unbounded;
         One : constant String := To_String (Entered (1));
      begin
         Assert (One'Length >= 6 and then One (One'First .. One'First + 4) = "first" and then One (One'Last) = 'X',
                 "dictation lost the typed text or the key pressed while it was heard: [" & One & "]");
         Assert (To_String (Entered (2)) = "second",
                 "a dropped recording changed the line: [" & To_String (Entered (2)) & "]; the screen ended: " & Tail);
         Assert (To_String (Entered (3)) = "third",
                 "Ctrl-_ did not take the transcript out: [" & To_String (Entered (3)) & "]");
      end;
   end Dictation_In_A_Session;

   ----------
   -- Name --
   ----------

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("speech");
   end Name;

   -----------------------------
   -- The_Device_Turn_Is_Lent --
   -----------------------------

   --  The device's turn: lent at first, borrowed by one at a time, not
   --  borrowed once taken back, and taken back only when the borrower has
   --  given it back.
   procedure The_Device_Turn_Is_Lent
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Device renames Model_Runner.Backend.Device;
      Got, Again : Boolean;

      task Taker is
         entry Go;
         entry Done;
      end Taker;

      --  Either rendezvous may never come where an assertion fails first,
      --  and the test must still end; where the turn never comes back the
      --  taker waits in it, and is aborted.
      task body Taker is
      begin
         select
            accept Go;
         or
            terminate;
         end select;
         Device.Take_Turn;
         select
            accept Done;
         or
            terminate;
         end select;
      end Taker;
   begin
      Device.Borrow_Turn (Got);
      Assert (Got, "the turn was not lent outside a session");
      Device.Borrow_Turn (Again);
      Assert (not Again, "the turn was borrowed twice at once");

      --  Taken back while borrowed: the taker waits for the borrower.
      Taker.Go;
      delay 0.2;
      select
         Taker.Done;
         Assert (False, "the turn was taken back while it was borrowed");
      else
         null;
      end select;
      Device.Return_Turn;
      select
         Taker.Done;
      or
         delay 10.0;
         abort Taker;
         Assert (False, "the turn was not taken back once it was given back");
      end select;

      Device.Borrow_Turn (Got);
      Assert (not Got, "the turn was borrowed after it was taken back");
      Device.Lend_Turn;
      Device.Borrow_Turn (Got);
      Assert (Got, "the turn was not borrowed once lent again");
      Device.Return_Turn;
   end The_Device_Turn_Is_Lent;

   ---------------------------------
   -- Whisper_Hears_On_The_Device --
   ---------------------------------

   --  The encoder on the device, in shapes its tile and attention take:
   --  what it heard is the processor's to half precision, its products ran
   --  there, and its matrices were given back; a recording transcribed
   --  with every token on the device says what the processor's does; with
   --  the turn not lent it runs on the processor and the device is not
   --  asked. Passes with nothing compared where no device opens.
   procedure Whisper_Hears_On_The_Device
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Device renames Model_Runner.Backend.Device;
      Path     : constant String := "obj/whisper-fixture-wide.gguf";
      Model    : aliased W.Model;
      Session  : W.Session;
      Status   : E.Error_Info;
      Ready    : Boolean;
      Mel      : Ts.Real_Array_Access := new N.Real_Array (0 .. 80 * 3_000 - 1);
      Here, There : Ts.Real_Array_Access := new N.Real_Array (0 .. 1_500 * 128 - 1);
      Worst, Largest : Long_Float := 0.0;
      Held, Tiled : Natural;
   begin
      for I in Mel'Range loop
         Mel (I) := N.Real (0.5 * Noise (Natural (I)));
      end loop;
      Whisper_Fixture.Write (Path, Wide => True);
      W.Prepare (Model, Path, Status);
      Assert (E.Is_Ok (Status), "the wide fixture was refused: " & Status.Code'Image);
      W.Open (Session, Model'Access, null, Status);
      W.Encode (Session, Mel.all, Status);
      Assert (E.Is_Ok (Status), "the processor did not encode: " & Status.Code'Image);
      W.Copy_Encoded (Session, Here.all);

      Device.Open (Ready);
      if Ready then
         Held := Device.Resident;
         Tiled := Device.Tiled_Products + Device.Untiled_Products;
         W.Use_Device (Session, True);
         W.Encode (Session, Mel.all, Status);
         Assert (E.Is_Ok (Status), "the device did not encode: " & Status.Code'Image);
         W.Copy_Encoded (Session, There.all);
         Assert (Device.Tiled_Products + Device.Untiled_Products > Tiled, "no product ran on the device");
         Assert (Device.Resident = Held, "the encoder's matrices were left on the device");
         for I in Here'Range loop
            Worst := Long_Float'Max (Worst, abs Long_Float (Here (I) - There (I)));
            Largest := Long_Float'Max (Largest, abs Long_Float (Here (I)));
         end loop;
         Assert (Worst <= 2.0E-2 * Largest, "the device heard otherwise: worst" & Worst'Image & " of" & Largest'Image);

         --  And a recording heard whole: every token on the device, its
         --  text the processor's.
         declare
            use Ada.Strings.Unbounded;
            Sound    : N.Real_Array (0 .. 15_999);
            Settings : W.Options;
            Alone, Beside : W.Transcript;
         begin
            for I in Sound'Range loop
               Sound (I) := N.Real (0.3 * Noise (Natural (I) + 7));
            end loop;
            Settings.Language := To_Unbounded_String ("en");
            Settings.Temperature_Count := 1;
            W.Use_Device (Session, False);
            W.Transcribe (Session, Sound, Settings, Alone, Status);
            Assert (E.Is_Ok (Status), "the processor did not transcribe: " & Status.Code'Image);
            Assert (Alone.Figures.Device_Positions = 0, "the processor's transcript was decoded on the device");
            W.Use_Device (Session, True);
            W.Transcribe (Session, Sound, Settings, Beside, Status);
            Assert (E.Is_Ok (Status), "the device did not transcribe: " & Status.Code'Image);
            Assert (Beside.Figures.Device_Positions > 0
                    and then Beside.Figures.Device_Positions >= Beside.Figures.Tokens,
                    "the device decoded" & Beside.Figures.Device_Positions'Image & " positions of"
                    & Beside.Figures.Tokens'Image & " tokens");
            Assert (Beside.Text = Alone.Text, "the device heard [" & To_String (Beside.Text)
                    & "] where the processor heard [" & To_String (Alone.Text) & "]");
            --  Heard again, in the same part of the cache: each turn's part
            --  was once put past the last, and the cache grew by one every
            --  transcription.
            declare
               Reserved : constant N.Element_Count := Device.Cached_Elements;
               Claimed  : constant N.Element_Count := Device.Cache_Claimed;
            begin
               W.Transcribe (Session, Sound, Settings, Beside, Status);
               Assert (E.Is_Ok (Status), "the device did not transcribe again");
               Assert (Device.Cached_Elements = Reserved, "a second transcription grew the device's cache from"
                       & Reserved'Image & " to" & Device.Cached_Elements'Image);
               Assert (Device.Cache_Claimed = Claimed, "a transcription claimed the cache as a session's");
            end;
            --  A conversation claiming all of it, as its pages grow into
            --  the room the last transcription left without the cache
            --  growing: the next is put past it, not over its rows.
            declare
               Reserved : constant N.Element_Count := Device.Cached_Elements;
               Met      : Boolean;
            begin
               Device.Reserve_Cache (Reserved, 0, Met);
               Assert (Met and then Device.Cache_Claimed = Reserved, "the conversation's room was not claimed");
               W.Transcribe (Session, Sound, Settings, Beside, Status);
               Assert (E.Is_Ok (Status), "the device did not transcribe past the conversation");
               Assert (Beside.Text = Alone.Text, "past the conversation the device heard otherwise");
               Assert (Device.Cached_Elements > Reserved, "the transcription was put over the conversation's rows");
               Assert (Device.Cache_Claimed = Reserved, "the transcription moved the conversation's claim");
               Device.Release_Cache;
            end;
            Assert (Device.Resident = Held, "the decoder's matrices were left on the device");
         end;

         --  The turn not lent: the processor's, the device not asked.
         Device.Take_Turn;
         Tiled := Device.Tiled_Products + Device.Untiled_Products;
         W.Encode (Session, Mel.all, Status);
         Device.Lend_Turn;
         Assert (E.Is_Ok (Status), "the processor did not encode without the turn");
         Assert (Device.Tiled_Products + Device.Untiled_Products = Tiled, "the device was asked without the turn");
         W.Copy_Encoded (Session, There.all);
         Assert (N."=" (There.all, Here.all), "without the turn the encoder was not the processor's");
         Device.Close;
      else
         Device_Notes.Skip ("for Whisper to hear on");
      end if;
      W.Close (Session);
      W.Close (Model, Status);
      Ts.Free (Mel);
      Ts.Free (Here);
      Ts.Free (There);
   end Whisper_Hears_On_The_Device;

   --------------------
   -- Register_Tests --
   --------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
   begin
      Register_Routine
        (T, Fourier_Is_The_Definition'Access,
         "the Fourier transform is its definition for lengths of every factor");
      Register_Routine
        (T, Fourier_Of_Known_Signals'Access,
         "an impulse, a constant and a cosine transform to what they are");
      Register_Routine
        (T, Mel_Filters_Are_The_Reference'Access,
         "the Mel filters are the reference's");
      Register_Routine
        (T, Wave_Encodings_Are_Read'Access,
         "a WAV file's encodings read to the same samples");
      Register_Routine
        (T, Wave_Refusals'Access,
         "a WAV file not read is refused by name, and a long one before decoding");
      Register_Routine
        (T, Resampling_Keeps_A_Tone'Access,
         "a rate changed keeps a tone and drops what the new rate cannot hold");
      Register_Routine
        (T, Spectrograms_Are_The_Reference'Access,
         "a recording's log-Mel spectrogram is the reference's");
      Register_Routine
        (T, Spectrogram_Of_Silence'Access,
         "silence is the floor and a short recording is padded, not read past");
      Register_Routine
        (T, Decoding_Rules_Are_The_Reference'Access,
         "a Whisper step allows what the reference's rules allow");
      Register_Routine
        (T, Picking_And_Measuring'Access,
         "greedy picks the first largest, log probabilities are log-softmax, repeats compress");
      Register_Routine
        (T, Sampling_At_A_Temperature'Access,
         "a sampled token is the reference's draw over a temperature, from a stream the same for its seed");
      Register_Routine
        (T, Whisper_Files_Are_Held_To_The_Profile'Access,
         "a Whisper file not of the profile is refused by name and leaves no model");
      Register_Routine
        (T, Whisper_Lifecycle'Access,
         "a Whisper model does not close under its session");
      Register_Routine
        (T, Whisper_Transcribes_And_Refuses'Access,
         "a Whisper session hears, detects, refuses past its context and stops when cancelled");
      Register_Routine
        (T, The_Device_Turn_Is_Lent'Access,
         "the device's turn is lent, borrowed by one at a time and taken back once given back");
      Register_Routine
        (T, Whisper_Hears_On_The_Device'Access,
         "the encoder and decoder on the device hear what the processor does, give their matrices back"
         & " and need the turn");
      Register_Routine
        (T, Word_Timing_Arithmetic'Access,
         "a word's time is warped and filtered as the reference's timing does it");
      Register_Routine
        (T, Spoken_Text_Goes_In_Where_The_Cursor_Is'Access,
         "what is heard goes in at the cursor, spaced, one line, never as a command");
      Register_Routine
        (T, Recognizer_Lifecycle'Access,
         "speech is off without a model, fails by name without one, refuses two at once, gives its model back");
      Register_Routine
        (T, Speech_Input_Without_A_Model'Access,
         "a session with no speech model records nothing and says why");
      Register_Routine
        (T, Speech_Is_Admitted_By_Memory'Access,
         "a speech model is refused where it and the conversation's do not fit");
      Register_Routine
        (T, Speech_Leaves_The_Conversation_Alone'Access,
         "a conversation's logits are the same with a speech model heard beside it");
      Register_Routine
        (T, Dictation_In_A_Session'Access,
         "a session dictates into the line, keeps keys pressed meanwhile, drops on Escape and undoes on Ctrl-_");
   end Register_Tests;

end Tests.Speech_Cases;
