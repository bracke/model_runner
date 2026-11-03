with Ada.Calendar;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Model_Runner.Audio;
with Model_Runner.Audio.Spectrograms;
with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Platform;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Model_Runner.Tokenizer;
with Model_Runner.Whisper;

package body Speech_Hear is

   package CPU renames Model_Runner.Backend.CPU;
   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;
   package W renames Model_Runner.Whisper;

   use Ada.Strings.Unbounded;
   use type N.Element_Count;
   use type T.Real_Array_Access;

   procedure Say (Text : String) is
   begin
      Ada.Text_IO.Put_Line ("hear: " & Text);
      Ada.Text_IO.Flush;
   end Say;

   --  A file of binary32 values, or null where there is none.
   function Values_Of (Path : String) return T.Real_Array_Access is
      use Ada.Streams.Stream_IO;
      File   : File_Type;
      Result : T.Real_Array_Access;
   begin
      if not Ada.Directories.Exists (Path) then
         return null;
      end if;
      T.Allocate (N.Element_Count (Ada.Directories.Size (Path)) / 4, Result);
      Open (File, In_File, Path, Form => "shared=no");
      N.Real_Array'Read (Stream (File), Result.all);
      Close (File);
      return Result;
   end Values_Of;

   --  The worst absolute difference, and it over the reference's largest
   --  magnitude.
   procedure Compare (What : String; Got, Expected : N.Real_Array; Tolerance : Long_Float; Failed : in out Boolean) is
      Worst, Largest : Long_Float := 0.0;
   begin
      for I in Expected'Range loop
         Worst := Long_Float'Max
           (Worst, abs (Long_Float (Got (Got'First + (I - Expected'First))) - Long_Float (Expected (I))));
         Largest := Long_Float'Max (Largest, abs Long_Float (Expected (I)));
      end loop;
      Say (What & ": worst absolute" & Worst'Image & ", relative to the largest" & Long_Float'Image (Worst / Largest)
           & (if Worst / Largest > Tolerance then "  OUTSIDE" & Tolerance'Image else ""));
      if Worst / Largest > Tolerance then
         Failed := True;
      end if;
   end Compare;

   --  A parameter's text, or "".
   function Detail (Status : E.Error_Info; Name : String) return String is
      Found : Boolean;
      Held  : E.Parameter;
   begin
      E.Find_Parameter (Status, Name, Found, Held);
      return (if Found then " " & Name & "=" & Model_Runner.Text.To_String (Held.Text_Value) else "");
   end Detail;

   function Run
     (Model, Audio, Language, Reference : String;
      Threads : Natural;
      Repeats : Positive;
      Fast_Detect : Boolean := False;
      Words : Boolean := False;
      Device : Boolean := False) return Natural
   is
      Whisper : aliased W.Model;
      Samples : T.Real_Array_Access;
      Status  : E.Error_Info;
      Failed  : Boolean := False;
      Started : constant Ada.Calendar.Time := Ada.Calendar.Clock;

      procedure Hear (Team : CPU.Pool_Reference) is
         use type Ada.Calendar.Time;
         Session : W.Session;
         Heard   : W.Transcript;
         Settings : W.Options;
      begin
         W.Open (Session, Whisper'Access, Team, Status);
         if E.Is_Error (Status) then
            Say ("session refused: " & Status.Code'Image);
            Failed := True;
            return;
         end if;
         W.Use_Device (Session, Device, Keep => True);

         if Reference /= "" then
            declare
               Encoded  : constant T.Real_Array_Access := Values_Of (Reference & "/encoded.f32");
               Expected : constant T.Real_Array_Access := Values_Of (Reference & "/first_logits.f32");
               Mel      : T.Real_Array_Access;
               Window   : T.Real_Array_Access;
               Frames   : N.Element_Count;
            begin
               --  The reference's first window: the spectrogram's first
               --  3,000 frames, the padding's own after a short recording.
               Model_Runner.Audio.Spectrograms.Log_Mel (Samples.all, 80, 480_000, Mel, Status);
               Frames := Model_Runner.Audio.Spectrograms.Frames_Of (Samples.all'Length, 480_000);
               T.Allocate (80 * 3_000, Window);
               for C in N.Element_Count'(0) .. 79 loop
                  Window (C * 3_000 .. C * 3_000 + 2_999) := Mel (C * Frames .. C * Frames + 2_999);
               end loop;
               declare
                  Before : constant Ada.Calendar.Time := Ada.Calendar.Clock;
               begin
                  W.Encode (Session, Window.all, Status);
                  Say ("encoder:" & Duration'Image (Ada.Calendar.Clock - Before) & " s");
               end;
               if E.Is_Error (Status) then
                  Say ("encoder failed: " & Status.Code'Image);
                  Failed := True;
               elsif Encoded /= null then
                  declare
                     Got : T.Real_Array_Access;
                  begin
                     T.Allocate (Encoded.all'Length, Got);
                     W.Copy_Encoded (Session, Got.all);
                     Compare ("encoder output", Got.all, Encoded.all, 1.0E-3, Failed);
                     T.Free (Got);
                  end;
               end if;
               if E.Is_Ok (Status) and then Expected /= null then
                  declare
                     Room   : T.Real_Array_Access := new N.Real_Array (0 .. Expected.all'Length - 1);
                     Logits : N.Real_Array renames Room.all;
                     Prompt : constant Model_Runner.Tokenizer.Token_Array :=
                       [50258, (if Language = "da" then 50285 else 50259), 50359];
                  begin
                     W.Decode (Session, Prompt, Logits, Status);
                     if E.Is_Error (Status) then
                        Say ("decoder failed: " & Status.Code'Image);
                        Failed := True;
                     else
                        Compare ("first logits", Logits, Expected.all, 1.0E-3, Failed);
                     end if;
                     T.Free (Room);
                  end;
               end if;
            end;
         end if;

         Settings.Language := To_Unbounded_String (Language);
         Settings.Detect_From_Window := Fast_Detect;
         Settings.Word_Timestamps := Words;
         for Round in 1 .. Repeats loop
            declare
               Before : constant Ada.Calendar.Time := Ada.Calendar.Clock;
            begin
               W.Transcribe (Session, Samples.all, Settings, Heard, Status);
               if E.Is_Error (Status) then
                  Say ("transcription failed: " & Status.Code'Image);
                  Failed := True;
                  exit;
               end if;
               Say ("round" & Round'Image & ":" & Duration'Image (Ada.Calendar.Clock - Before) & " s for"
                    & Heard.Figures.Audio_Seconds'Image & " s of sound; spectrogram"
                    & Heard.Figures.Spectrogram_Seconds'Image & ", encoder" & Heard.Figures.Encoder_Seconds'Image
                    & ", decoder" & Heard.Figures.Decoder_Seconds'Image & ";" & Heard.Figures.Windows'Image
                    & " windows," & Heard.Figures.Tokens'Image & " tokens," & Heard.Figures.Device_Positions'Image
                    & " positions on the device");
            end;
         end loop;
         if E.Is_Ok (Status) then
            Say ("language: " & To_String (Heard.Language));
            for Piece of Heard.Segments loop
               Say ("[" & Piece.Start_Seconds'Image & " -->" & Piece.End_Seconds'Image & "]"
                    & (if Piece.Silent then " (silent)" else "")
                    & (if Piece.Uncertain then " (uncertain)" else "")
                    & " logprob" & Piece.Average_Log_Probability'Image
                    & " no-speech" & Piece.No_Speech_Probability'Image
                    & " ratio" & Piece.Compression_Ratio'Image & " t" & Piece.Temperature'Image
                    & " " & To_String (Piece.Text));
               for Word of Piece.Words loop
                  Say ("    " & To_String (Word.Text) & Word.Start_Seconds'Image & Word.End_Seconds'Image
                       & Word.Probability'Image);
               end loop;
            end loop;
            Say ("text: " & To_String (Heard.Text));
         end if;
         W.Close (Session);
      end Hear;
   begin
      W.Prepare (Whisper, Model, Status);
      if E.Is_Error (Status) then
         Say ("model refused: " & Status.Code'Image & " " & Detail (Status, "tensor") & Detail (Status, "key"));
         return 1;
      end if;
      Say ("model: " & W.Name (Whisper) & ", prepared in"
           & Duration'Image (Ada.Calendar."-" (Ada.Calendar.Clock, Started))
           & " s; weights" & W.Weight_Bytes (Whisper)'Image & " bytes, a session" & W.Session_Bytes (Whisper)'Image);
      Model_Runner.Audio.Read_Wave (Audio, 3_600, Samples, Status);
      if E.Is_Error (Status) then
         Say ("recording refused: " & Status.Code'Image);
         return 1;
      end if;

      if Device then
         declare
            Ready : Boolean;
         begin
            Model_Runner.Backend.Device.Open (Ready);
            Say ("device: " & (if Ready then Model_Runner.Backend.Device.Name else "none opened"));
         end;
      end if;

      declare
         Wanted : constant Positive :=
           (if Threads > 0 then Threads else Positive (CPU.Default_Workers (Model_Runner.Platform.Core_Count)));
      begin
         if Wanted = 1 then
            Hear (null);
         else
            declare
               Team : aliased CPU.Pool (CPU.Worker_Count (Wanted));
            begin
               CPU.Open (Team);
               Hear (Team'Unchecked_Access);
               CPU.Close (Team);
            exception
               when others =>
                  CPU.Close (Team);
                  raise;
            end;
         end if;
      end;
      T.Free (Samples);
      W.Close (Whisper, Status);
      if Device then
         Model_Runner.Backend.Device.Close;
      end if;
      return (if Failed then 1 else 0);
   end Run;

end Speech_Hear;
