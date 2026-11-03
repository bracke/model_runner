with Ada.Calendar;
with Ada.Directories;
with Ada.Numerics.Long_Elementary_Functions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;

with Model_Runner.Audio;
with Model_Runner.Backend.CPU;
with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Platform;
with Model_Runner.Tensors;
with Model_Runner.UTF8;
with Model_Runner.Whisper;

package body Speech_Corpus is

   package CPU renames Model_Runner.Backend.CPU;
   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;
   package W renames Model_Runner.Whisper;
   package F renames Ada.Numerics.Long_Elementary_Functions;

   use Ada.Strings.Unbounded;
   use type N.Element_Count;
   use type T.Real_Array_Access;
   use type Interfaces.Unsigned_32;

   procedure Say (Text : String) is
   begin
      Ada.Text_IO.Put_Line (Text);
      Ada.Text_IO.Flush;
   end Say;

   --  A text as it is compared: lower case, punctuation gone, spaces run
   --  together, ends trimmed. Danish capitals lowered as well as ASCII.
   function Normal (Text : String) return String is
      Upper : constant array (1 .. 3) of String (1 .. 2) :=
        [[Character'Val (16#C3#), Character'Val (16#86#)],
         [Character'Val (16#C3#), Character'Val (16#98#)],
         [Character'Val (16#C3#), Character'Val (16#85#)]];
      Lower : constant array (1 .. 3) of String (1 .. 2) :=
        [[Character'Val (16#C3#), Character'Val (16#A6#)],
         [Character'Val (16#C3#), Character'Val (16#B8#)],
         [Character'Val (16#C3#), Character'Val (16#A5#)]];
      Result : Unbounded_String;
      I      : Natural := Text'First;
      Gap    : Boolean := True;
   begin
      while I <= Text'Last loop
         declare
            Ch : Character := Text (I);
            Done : Boolean := False;
         begin
            if I < Text'Last then
               for K in Upper'Range loop
                  if Text (I .. I + 1) = Upper (K) then
                     Append (Result, Lower (K));
                     I := I + 2;
                     Gap := False;
                     Done := True;
                     exit;
                  end if;
               end loop;
            end if;
            if not Done then
               if Ch in 'A' .. 'Z' then
                  Ch := Character'Val (Character'Pos (Ch) + 32);
               end if;
               if Ch in '.' | ',' | '!' | '?' | ';' | ':' | '"' | '(' | ')' | '-' | '''
                 | ' ' | ASCII.HT | ASCII.LF | ASCII.CR
               then
                  if not Gap then
                     Append (Result, ' ');
                     Gap := True;
                  end if;
               else
                  Append (Result, Ch);
                  Gap := False;
               end if;
               I := I + 1;
            end if;
         end;
      end loop;
      return Ada.Strings.Fixed.Trim (To_String (Result), Ada.Strings.Both);
   end Normal;

   --  A number to two places: 12.34.
   function Two_Places (X : Long_Float) return String is
      Hundredths : constant Natural := Natural (Long_Float'Max (0.0, X) * 100.0);
      Part       : constant String := Natural'Image (100 + Hundredths mod 100);
   begin
      return Ada.Strings.Fixed.Trim (Natural'Image (Hundredths / 100), Ada.Strings.Left) & "."
        & Part (Part'Last - 1 .. Part'Last);
   end Two_Places;

   type Unit_List is array (Positive range <>) of Unbounded_String;

   function Words_Of (Text : String) return Unit_List is
      Count : Natural := 0;
   begin
      for C of Text loop
         if C = ' ' then
            Count := Count + 1;
         end if;
      end loop;
      declare
         Result : Unit_List (1 .. (if Text = "" then 0 else Count + 1));
         Start  : Positive := Text'First;
         Index  : Natural := 0;
      begin
         for I in Text'Range loop
            if Text (I) = ' ' or else I = Text'Last then
               Index := Index + 1;
               Result (Index) := To_Unbounded_String (Text (Start .. (if Text (I) = ' ' then I - 1 else I)));
               Start := I + 1;
            end if;
         end loop;
         return Result;
      end;
   end Words_Of;

   function Characters_Of (Text : String) return Unit_List is
      Result : Unit_List (1 .. Model_Runner.UTF8.Code_Point_Count (Text));
      I      : Natural := Text'First;
   begin
      for K in Result'Range loop
         declare
            Length : constant Natural := Natural'Max (1, Model_Runner.UTF8.Sequence_Length (Text (I)));
         begin
            Result (K) := To_Unbounded_String (Text (I .. Natural'Min (Text'Last, I + Length - 1)));
            I := I + Length;
         end;
      end loop;
      return Result;
   end Characters_Of;

   --  The fewest insertions, deletions and substitutions from one to the
   --  other.
   function Distance (From, To : Unit_List) return Natural is
      type Row_Of_Costs is array (0 .. To'Length) of Natural;
      Row, Next : Row_Of_Costs;
   begin
      for J in Row'Range loop
         Row (J) := J;
      end loop;
      for I in From'Range loop
         Next (0) := I - From'First + 1;
         for J in 1 .. To'Length loop
            Next (J) := Natural'Min
              (Natural'Min (Row (J) + 1, Next (J - 1) + 1),
               Row (J - 1) + (if From (I) = To (To'First + J - 1) then 0 else 1));
         end loop;
         Row := Next;
      end loop;
      return Row (To'Length);
   end Distance;

   function Field (Line : String; Index : Positive) return String is
      Start : Positive := Line'First;
      Count : Positive := 1;
   begin
      for I in Line'Range loop
         if Line (I) = '|' and then Count < 4 then
            if Count = Index then
               return Line (Start .. I - 1);
            end if;
            Count := Count + 1;
            Start := I + 1;
         end if;
      end loop;
      return (if Count = Index then Line (Start .. Line'Last) else "");
   end Field;

   function Run (Model, Corpus : String; Threads : Natural) return Natural is
      Manifest : constant String := (if Corpus = "" then "fixtures/speech/corpus.txt" else Corpus);
      Folder   : constant String := Ada.Directories.Containing_Directory (Manifest);
      Whisper  : aliased W.Model;
      Status   : E.Error_Info;
      Failed   : Boolean := False;

      type Totals is record
         Word_Errors, Words, Character_Errors, Characters : Natural := 0;
         Audio, Spent : Long_Float := 0.0;
      end record;
      English, Danish : Totals;
      Silent_Words : Natural := 0;

      procedure Hear (Team : CPU.Pool_Reference) is
         Session : W.Session;
         File    : Ada.Text_IO.File_Type;
         Draws   : Interfaces.Unsigned_32 := 12_345;

         --  A uniform noise sample in -1 .. 1, the same every run.
         function Noise return Long_Float is
         begin
            Draws := Draws * 1_664_525 + 1_013_904_223;
            return Long_Float (Draws) / 2_147_483_648.0 - 1.0;
         end Noise;
      begin
         W.Open (Session, Whisper'Access, Team, Status);
         if E.Is_Error (Status) then
            Say ("speech-corpus: session refused: " & Status.Code'Image);
            Failed := True;
            return;
         end if;
         Say ("recording        lang  noise      WER      CER  heard  seconds  of sound  transcript");
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Manifest, Form => "shared=no");
         while not Ada.Text_IO.End_Of_File (File) loop
            declare
               Line     : constant String := Ada.Text_IO.Get_Line (File);
               Name     : constant String := (if Line'Length > 0 and then Line (Line'First) /= '#'
                                              then Field (Line, 1) else "");
               Language : constant String := Field (Line, 2);
               Noise_At : constant String := Field (Line, 3);
               Said     : constant String := Field (Line, 4);
               Samples  : T.Real_Array_Access;
               Heard    : W.Transcript;
               Settings : W.Options;
            begin
               if Name /= "" then
                  if Name'Length > 8 and then Name (Name'First .. Name'First + 7) = "silence:" then
                     T.Allocate (N.Element_Count'Value (Name (Name'First + 8 .. Name'Last)) * 16_000, Samples);
                  else
                     Model_Runner.Audio.Read_Wave (Folder & "/" & Name, 3_600, Samples, Status);
                     if E.Is_Error (Status) then
                        Say ("speech-corpus: " & Name & " refused: " & Status.Code'Image);
                        Failed := True;
                     end if;
                  end if;
                  if Samples /= null and then Noise_At /= "-" then
                     --  White noise at the stated ratio to the speech's
                     --  power, or for silence at that level below full scale.
                     declare
                        Power : Long_Float := 0.0;
                        Ratio : constant Long_Float := Long_Float'Value (Noise_At);
                        Level : Long_Float;
                     begin
                        for V of Samples.all loop
                           Power := Power + Long_Float (V) ** 2;
                        end loop;
                        Power := Power / Long_Float (Samples.all'Length);
                        Level := (if Power = 0.0 then F."**" (10.0, -Ratio / 20.0)
                                  else F.Sqrt (Power / F."**" (10.0, Ratio / 10.0)));
                        --  A uniform sample's power is a third.
                        for V of Samples.all loop
                           V := N.Real (Long_Float (V) + Level * F.Sqrt (3.0) * Noise);
                        end loop;
                     end;
                  end if;
                  if Samples /= null then
                     declare
                        use type Ada.Calendar.Time;
                        Before : constant Ada.Calendar.Time := Ada.Calendar.Clock;
                        Spent  : Long_Float;
                     begin
                        Settings.Language := To_Unbounded_String (Language);
                        W.Transcribe (Session, Samples.all, Settings, Heard, Status);
                        Spent := Long_Float (Ada.Calendar.Clock - Before);
                        if E.Is_Error (Status) then
                           Say ("speech-corpus: " & Name & " not heard: " & Status.Code'Image);
                           Failed := True;
                        else
                           --  The language as heard, without being told.
                           declare
                              Detected : W.Transcript;
                              Asked    : W.Options;
                           begin
                              Asked.Detect_From_Window := True;
                              Asked.Temperature_Count := 1;
                              W.Transcribe (Session, Samples.all, Asked, Detected, Status);
                              declare
                                 Got     : constant String := Normal (To_String (Heard.Text));
                                 Wanted  : constant String := Normal (Said);
                                 Word_Errors : constant Natural := Distance (Words_Of (Wanted), Words_Of (Got));
                                 Char_Errors : constant Natural :=
                                   Distance (Characters_Of (Wanted), Characters_Of (Got));
                                 Word_Count  : constant Natural := Words_Of (Wanted)'Length;
                                 Char_Count  : constant Natural := Characters_Of (Wanted)'Length;
                                 procedure Count_In (Sum : in out Totals) is
                                 begin
                                    if Word_Count = 0 then
                                       Silent_Words := Silent_Words + Words_Of (Got)'Length;
                                    else
                                       Sum.Word_Errors := Sum.Word_Errors + Word_Errors;
                                       Sum.Words := Sum.Words + Word_Count;
                                       Sum.Character_Errors := Sum.Character_Errors + Char_Errors;
                                       Sum.Characters := Sum.Characters + Char_Count;
                                    end if;
                                    Sum.Audio := Sum.Audio + Long_Float (Heard.Figures.Audio_Seconds);
                                    Sum.Spent := Sum.Spent + Spent;
                                 end Count_In;
                                 function Percent (Errors, Count : Natural) return String is
                                   (if Count = 0 then "     -"
                                    else Ada.Strings.Fixed.Tail
                                      (Two_Places (Long_Float (Errors) * 100.0 / Long_Float (Count)) & "%", 7));
                              begin
                                 if Language = "da" then
                                    Count_In (Danish);
                                 else
                                    Count_In (English);
                                 end if;
                                 Say (Ada.Strings.Fixed.Head (Name, 16) & " " & Ada.Strings.Fixed.Head (Language, 4)
                                      & "  " & Ada.Strings.Fixed.Head (Noise_At, 5)
                                      & "  " & Percent (Word_Errors, Word_Count)
                                      & "  " & Percent (Char_Errors, Char_Count)
                                      & "  " & Ada.Strings.Fixed.Head (To_String (Detected.Language), 4)
                                      & "  " & Ada.Strings.Fixed.Tail (Two_Places (Spent), 7)
                                      & "  " & Ada.Strings.Fixed.Tail
                                        (Two_Places (Long_Float (Heard.Figures.Audio_Seconds)), 7)
                                      & "  " & Got);
                              end;
                           end;
                        end if;
                     end;
                     T.Free (Samples);
                  end if;
               end if;
            end;
         end loop;
         Ada.Text_IO.Close (File);
         W.Close (Session);
         for Language in 1 .. 2 loop
            declare
               Sum : constant Totals := (if Language = 1 then English else Danish);
            begin
               if Sum.Words > 0 then
                  Say ((if Language = 1 then "en" else "da") & ": WER "
                       & Two_Places (Long_Float (Sum.Word_Errors) * 100.0 / Long_Float (Sum.Words)) & "%, CER "
                       & Two_Places (Long_Float (Sum.Character_Errors) * 100.0 / Long_Float (Sum.Characters))
                       & "%, over" & Sum.Words'Image & " words; real-time factor "
                       & Two_Places (Sum.Spent / Sum.Audio));
               end if;
            end;
         end loop;
         Say ("words heard in silence:" & Silent_Words'Image);
      end Hear;
   begin
      W.Prepare (Whisper, Model, Status);
      if E.Is_Error (Status) then
         Say ("speech-corpus: model refused: " & Status.Code'Image);
         return 1;
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
      W.Close (Whisper, Status);
      return (if Failed then 1 else 0);
   end Run;

end Speech_Corpus;
