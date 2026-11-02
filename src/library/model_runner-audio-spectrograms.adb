with Ada.Numerics;
with Ada.Numerics.Generic_Elementary_Functions;

with Model_Runner.Fourier;

package body Model_Runner.Audio.Spectrograms is

   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;

   subtype Wide_Real is N.Wide_Real;

   package Elementary is new Ada.Numerics.Generic_Elementary_Functions (Wide_Real);

   use type Wide_Real;
   use type N.Real;
   use type T.Real_Array_Access;

   --  Slaney's mel scale: linear below 1 kHz, 200 / 3 Hz a mel; past it,
   --  logarithmic, 27 mels to a factor of 6.4.
   Linear_Step  : constant Wide_Real := 200.0 / 3.0;
   Knee_Hz      : constant Wide_Real := 1_000.0;
   Knee_Mel     : constant Wide_Real := Knee_Hz / Linear_Step;

   function Log_Step return Wide_Real is (Elementary.Log (6.4) / 27.0);

   function Hz_To_Mel (Hz : Wide_Real) return Wide_Real is
     (if Hz >= Knee_Hz then Knee_Mel + Elementary.Log (Hz / Knee_Hz) / Log_Step
      else Hz / Linear_Step);

   function Mel_To_Hz (Mel : Wide_Real) return Wide_Real is
     (if Mel >= Knee_Mel then Knee_Hz * Elementary.Exp (Log_Step * (Mel - Knee_Mel))
      else Linear_Step * Mel);

   -----------------
   -- Mel_Filters --
   -----------------

   procedure Mel_Filters (Mels : Mel_Count; Into : out Real_Array) is
      Nyquist : constant Wide_Real := Wide_Real (Canonical_Rate) / 2.0;
      Top     : constant Wide_Real := Hz_To_Mel (Nyquist);
      --  The filters' edges: Mels + 2 points evenly on the mel scale.
      Edges   : array (0 .. Mels + 1) of Wide_Real;
   begin
      for I in Edges'Range loop
         Edges (I) := Mel_To_Hz (Top * Wide_Real (I) / Wide_Real (Mels + 1));
      end loop;
      for M in 0 .. Mels - 1 loop
         declare
            Area : constant Wide_Real := 2.0 / (Edges (M + 2) - Edges (M));
         begin
            for K in 0 .. Bins - 1 loop
               declare
                  Hz    : constant Wide_Real := Nyquist * Wide_Real (K) / Wide_Real (Bins - 1);
                  Lower : constant Wide_Real := (Hz - Edges (M)) / (Edges (M + 1) - Edges (M));
                  Upper : constant Wide_Real := (Edges (M + 2) - Hz) / (Edges (M + 2) - Edges (M + 1));
               begin
                  Into (Into'First + Element_Count (M * Bins + K)) :=
                    Real (Wide_Real'Max (0.0, Wide_Real'Min (Lower, Upper)) * Area);
               end;
            end loop;
         end;
      end loop;
   end Mel_Filters;

   -------------
   -- Log_Mel --
   -------------

   procedure Log_Mel
     (Samples : Real_Array;
      Mels    : Mel_Count;
      Padding : Element_Count;
      Into    : out T.Real_Array_Access;
      Status  : out E.Error_Info)
   is
      Length : constant Element_Count := Samples'Length + Padding;
      Frames : constant Element_Count := Frames_Of (Samples'Length, Padding);
      Half   : constant Element_Count := Window_Length / 2;

      Filters : Real_Array (0 .. Element_Count (Mels) * Bins - 1);
      --  Each filter's bins that are not zero.
      First_Bin, Last_Bin : array (0 .. Mels - 1) of Natural;

      Window : N.Wide_Real_Array (0 .. Window_Length - 1);
      Frame  : N.Wide_Real_Array (0 .. Window_Length - 1);
      Re, Im : N.Wide_Real_Array (0 .. Bins - 1);
      Power  : N.Wide_Real_Array (0 .. Bins - 1);
      Plan   : Model_Runner.Fourier.Plan (Window_Length);

      --  The padded, reflected signal's sample I: I counted from the
      --  first reflected sample.
      function Sample_At (I : Element_Count) return Wide_Real is
         Index : Element_Count;
      begin
         if I < Half then
            Index := Half - I;
         elsif I - Half < Length then
            Index := I - Half;
         else
            Index := 2 * (Length - 1) - (I - Half);
         end if;
         return (if Index < Samples'Length then Wide_Real (Samples (Samples'First + Index)) else 0.0);
      end Sample_At;

      Largest : Wide_Real := -1.0E30;
   begin
      Into := null;
      Status := E.Success;
      if Length <= Half then
         Status := E.Make (E.IO_Audio_Unreadable);
         E.Add_Text (Status, "detail", "fewer than" & Half'Image & " samples", E.Param_Identifier);
         return;
      end if;

      T.Allocate (Element_Count (Mels) * Frames, Into);
      if Into = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      Mel_Filters (Mels, Filters);
      for M in 0 .. Mels - 1 loop
         First_Bin (M) := Bins;
         Last_Bin (M) := 0;
         for K in 0 .. Bins - 1 loop
            if Filters (Element_Count (M * Bins + K)) /= 0.0 then
               First_Bin (M) := Natural'Min (First_Bin (M), K);
               Last_Bin (M) := K;
            end if;
         end loop;
      end loop;

      for I in Window'Range loop
         Window (I) := 0.5 - 0.5 * Elementary.Cos (2.0 * Ada.Numerics.Pi * Wide_Real (I) / Wide_Real (Window_Length));
      end loop;
      Model_Runner.Fourier.Prepare (Plan);

      for F in 0 .. Frames - 1 loop
         declare
            Start : constant Element_Count := F * Hop_Length;
            --  The window lies wholly in the padding past the samples and
            --  their reflection: its transform is zero, and is not taken.
            Silent : constant Boolean := Start >= Half + Samples'Length
              and then Start + Window_Length <= Half + Length;
         begin
            if Silent then
               Power := [others => 0.0];
            else
               for I in Frame'Range loop
                  Frame (I) := Sample_At (Start + I) * Window (I);
               end loop;
               Model_Runner.Fourier.Forward_Real (Plan, Frame, Re, Im);
               for K in Power'Range loop
                  --  Rounded to binary32, as the reference's power is.
                  Power (K) := Wide_Real (Real (Re (K) * Re (K) + Im (K) * Im (K)));
               end loop;
            end if;
            for M in 0 .. Mels - 1 loop
               declare
                  Sum : Wide_Real := 0.0;
               begin
                  for K in First_Bin (M) .. Last_Bin (M) loop
                     Sum := Sum + Wide_Real (Filters (Element_Count (M * Bins + K))) * Power (Element_Count (K));
                  end loop;
                  declare
                     Value : constant Wide_Real := Elementary.Log (Wide_Real'Max (Sum, 1.0E-10), 10.0);
                  begin
                     Largest := Wide_Real'Max (Largest, Value);
                     Into (Element_Count (M) * Frames + F) := Real (Value);
                  end;
               end;
            end loop;
         end;
      end loop;

      declare
         Floor : constant Real := Real (Largest - 8.0);
      begin
         for V of Into.all loop
            V := (Real'Max (V, Floor) + 4.0) / 4.0;
         end loop;
      end;
   end Log_Mel;

end Model_Runner.Audio.Spectrograms;
