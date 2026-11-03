--  A recording through a Whisper model, said: its transcript, its segments
--  and where the time went; and, given the reference's numbers for the
--  same recording, the encoder's output and the first logits held to them
--  (docs/plan-speech.md).
package Speech_Hear is

   --  Hear a recording.
   --
   --  @param Model The Whisper GGUF file.
   --  @param Audio A WAV file.
   --  @param Language A language's code, or "" to detect it.
   --  @param Reference A directory of the reference's dumps for the same
   --    recording -- encoded.f32, first_logits.f32, result.json's tokens --
   --    or "".
   --  @param Threads Workers, or 0 for the machine's default.
   --  @param Repeats Times to transcribe, for timing.
   --  @param Fast_Detect Read the language off the first window as decoded.
   --  @param Words Time each word, and say them.
   --  @return 0 when heard (and, given a reference, within its tolerance).
   function Run
     (Model, Audio, Language, Reference : String;
      Threads : Natural;
      Repeats : Positive;
      Fast_Detect : Boolean := False;
      Words : Boolean := False) return Natural;

end Speech_Hear;
