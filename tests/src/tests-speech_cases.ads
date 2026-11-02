with AUnit;
with Tests.Fresh_Cases;

--  Speech: the audio a speech model hears -- WAV files decoded, channels
--  mixed, rates changed, the Fourier transform and the log-Mel spectrogram
--  held to the reference's own numbers -- and the Whisper model itself
--  (docs/plan-speech.md).
package Tests.Speech_Cases is

   type Case_Type is new Tests.Fresh_Cases.Fresh_Case with null record;

   overriding function Name (T : Case_Type) return AUnit.Message_String;

   overriding procedure Register_Tests (T : in out Case_Type);

end Tests.Speech_Cases;
