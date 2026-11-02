with Ada.Numerics;
with Ada.Numerics.Long_Elementary_Functions;
with Ada.Text_IO;
with Ada.Unchecked_Conversion;
with Interfaces;

with AUnit.Assertions;
with AUnit.Test_Cases;

with Model_Runner.Audio;
with Model_Runner.Audio.Spectrograms;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.Fourier;
with Model_Runner.Numerics;
with Model_Runner.Tensors;

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
            Model_Runner.Fourier.Prepare (Plan);
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

   ----------
   -- Name --
   ----------

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("speech");
   end Name;

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
   end Register_Tests;

end Tests.Speech_Cases;
