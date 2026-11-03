with Ada.Strings.Unbounded;

with Model_Runner.Audio;
with Model_Runner.Speech;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Model_Runner.Whisper;

package body Model_Runner.CLI.Execute.Transcribe_Command is

   package W renames Model_Runner.Whisper;
   package Tn renames Model_Runner.Tensors;

   use type Tn.Real_Array_Access;

   --  A time as hours, minutes, seconds and milliseconds: 00:01:02.500.
   function Seconds_Image (Seconds : N.Real) return String is
      Total : constant Natural := Natural (Float'Floor (Float (Seconds) * 1000.0 + 0.5));
      function Two (Value : Natural; Width : Positive := 2) return String is
         Text : constant String := Natural'Image (Value);
         Bare : constant String := Text (Text'First + 1 .. Text'Last);
      begin
         return (if Bare'Length >= Width then Bare else [1 .. Width - Bare'Length => '0'] & Bare);
      end Two;
   begin
      return Two (Total / 3_600_000) & ":" & Two (Total / 60_000 mod 60) & ":" & Two (Total / 1_000 mod 60) & "."
        & Two (Total mod 1_000, 3);
   end Seconds_Image;

   -------------------
   -- Do_Transcribe --
   -------------------

   procedure Do_Transcribe
     (Item   : Opt.Command;
      Screen : in out Pres.Console;
      Status : out Natural)
   is
      use Ada.Strings.Unbounded;

      Model_Path : constant String := Model_Runner.Text.To_String (Item.Speech_Model_Path);
      Audio_Path : constant String := Model_Runner.Text.To_String (Item.Audio_Path);
      Whisper    : aliased W.Model;
      Samples    : Tn.Real_Array_Access;
      Condition  : E.Error_Info;
      Ignored    : E.Error_Info;

      procedure Fail (Problem : E.Error_Info) is
      begin
         Pres.Report (Screen, Problem);
         Status := E.Exit_Status (Problem);
      end Fail;

      procedure Hear (Team : Workers_CPU.Pool_Reference) is
         Session  : W.Session;
         Heard    : W.Transcript;
         Settings : W.Options;
      begin
         W.Open (Session, Whisper'Access, Team, Condition);
         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;
         Settings.Language := To_Unbounded_String (Model_Runner.Text.To_String (Item.Speech_Language));
         Settings.Translate := Item.Speech_Translate;
         Settings.Initial_Prompt := To_Unbounded_String (Model_Runner.Text.To_String (Item.Speech_Initial_Prompt));
         W.Transcribe (Session, Samples.all, Settings, Heard, Condition);
         W.Close (Session);
         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;
         if Item.Speech_Timestamps then
            for Piece of Heard.Segments loop
               if not Piece.Silent and then Length (Piece.Text) > 0 then
                  Pres.Put_Line
                    (Screen, "[" & Seconds_Image (Piece.Start_Seconds) & " --> " & Seconds_Image (Piece.End_Seconds)
                     & "]" & (if Piece.Uncertain then " (?)" else "") & To_String (Piece.Text));
               end if;
            end loop;
         else
            declare
               Text : constant String := To_String (Heard.Text);
               From : Positive := Text'First;
            begin
               --  The reference's text begins each segment with a space.
               while From <= Text'Last and then Text (From) = ' ' loop
                  From := From + 1;
               end loop;
               Pres.Put_Line (Screen, Text (From .. Text'Last));
            end;
         end if;
         Status := E.Exit_Success;
      end Hear;
   begin
      Status := E.Exit_Success;
      if Model_Path = "" then
         Condition := E.Make (E.CLI_Option_Required);
         E.Add_Text (Condition, "option", "--speech-model", E.Param_Identifier);
         E.Add_Text (Condition, "other", "transcribe", E.Param_Identifier);
         Fail (Condition);
         return;
      end if;
      if Audio_Path = "" then
         Condition := E.Make (E.CLI_Option_Required);
         E.Add_Text (Condition, "option", "FILE.wav", E.Param_Identifier);
         E.Add_Text (Condition, "other", "transcribe", E.Param_Identifier);
         Fail (Condition);
         return;
      end if;

      --  A file is not a microphone: an hour unless the length was asked.
      Model_Runner.Audio.Read_Wave
        (Audio_Path,
         (if Item.Speech_Max_Seconds_Set then Item.Speech_Max_Seconds else Model_Runner.Speech.Max_Recording_Seconds),
         Samples, Condition);
      if E.Is_Error (Condition) then
         Fail (Condition);
         return;
      end if;
      W.Prepare (Whisper, Model_Path, Condition);
      if E.Is_Error (Condition) then
         E.Add_Text (Condition, "path", Model_Path, E.Param_Path);
         Tn.Free (Samples);
         Fail (Condition);
         return;
      end if;

      declare
         Wanted : constant Positive := Selected_Workers (Item);
      begin
         if Wanted = 1 then
            Hear (null);
         else
            declare
               Team : aliased Workers_CPU.Pool (Workers_CPU.Worker_Count (Wanted));
            begin
               Workers_CPU.Open (Team);
               Hear (Team'Unchecked_Access);
               Workers_CPU.Close (Team);
            exception
               when others =>
                  Workers_CPU.Close (Team);
                  raise;
            end;
         end if;
      end;
      Tn.Free (Samples);
      W.Close (Whisper, Ignored);
   end Do_Transcribe;

end Model_Runner.CLI.Execute.Transcribe_Command;
