with Ada.Strings.Unbounded;
with Interfaces;

with Model_Runner.Backend.CPU;
with Model_Runner.Cancellation;
with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Whisper;

--  Speech input: a microphone recorded and what was said written out, by a
--  Whisper model held beside the conversation's own.
--
--  This is the auxiliary owner the speech specification asks for. It owns
--  everything speech uses -- the Whisper model and its session, a worker
--  pool of its own, the recording's buffer, the microphone -- and nothing
--  else. It is never given the conversation's model or session, so nothing
--  it does, fails at or gives up can change them; and it shares no buffer
--  with them. The two models share the machine: the processor's cores, and
--  memory, which is asked before the model is loaded -- the speech model is
--  refused, not the conversation's shrunk, where the two do not fit.
--
--  States, as the specification names them:
--
--    Disabled      no speech model was named; nothing is recorded
--    Unloaded      named and not yet read
--    Loading       being read, on the inference task
--    Ready         read, idle
--    Recording     the microphone open, its samples kept
--    Transcribing  the recording heard; the editor waits for its text
--    Failed        the model could not be read; the next start tries again
--    Unloading     being given back
--
--  The model is read on first use: the first Start loads it on the
--  inference task while the capture task already records, so nothing said
--  while it loads is lost. It stays loaded between recordings unless the
--  settings say otherwise.
--
--  One recording at a time: Start while one is recording or being heard is
--  refused (Lifecycle_Invalid_State, its state named). Cancel drops the
--  recording, or stops the hearing at its next token; the samples are
--  forgotten either way. Nothing recorded is written to a file.
--
--  The work runs on two tasks of its own: one reads the microphone a tenth
--  of a second at a time, the other loads the model and transcribes. The
--  calls below only post to them and read what they posted, and return at
--  once.
--
--  Task safety: a Recognizer is driven from one task -- the terminal's --
--  and its two tasks are its own. Shutdown must be called before the
--  program ends: it stops both tasks.
package Model_Runner.Speech is

   type State is
     (Disabled, Unloaded, Loading, Ready, Recording, Transcribing, Failed, Unloading);

   --  The state's name, for a message: "recording", "transcribing", ...
   --
   --  @param Item A state.
   --  @return Its name in lower case.
   function Image (Item : State) return String;

   --  What speech is set to.
   type Settings is record
      --  The Whisper file; empty, speech is Disabled.
      Model_Path     : Ada.Strings.Unbounded.Unbounded_String;
      --  The language spoken, as its code; empty, detected.
      Language       : Ada.Strings.Unbounded.Unbounded_String;
      --  The sound server's source; empty, its default.
      Source         : Ada.Strings.Unbounded.Unbounded_String;
      --  The longest recording; it stops itself there and is heard.
      Max_Seconds    : Positive := 120;
      --  Whether the model stays read between recordings.
      Keep_Loaded    : Boolean := True;
      --  Text the first window is prompted with: names, spellings.
      Initial_Prompt : Ada.Strings.Unbounded.Unbounded_String;
      --  Workers for the products, or 0 for the machine's default.
      Workers        : Natural := 0;
   end record;

   --  The longest recording a setting may ask: an hour.
   Max_Recording_Seconds : constant := 3_600;

   type Recognizer is limited private;
   type Recognizer_Access is access Recognizer;

   --  A recognizer with its two tasks waiting.
   --
   --  @param With_Settings What speech is set to.
   --  @return The recognizer; Shutdown gives it back.
   function Create (With_Settings : Settings) return Recognizer_Access;

   --  Stop whatever is under way, stop both tasks, give the model and the
   --  pool back, and free the recognizer. Null in, nothing done.
   --
   --  @param Item The recognizer; null afterwards.
   procedure Shutdown (Item : in out Recognizer_Access);

   --  @param Item A recognizer.
   --  @return Its state now.
   function Current (Item : Recognizer) return State;

   --  Begin recording, and reading the model if it is not read.
   --
   --  @param Item A recognizer.
   --  @param Status Success; Lifecycle_Speech_Disabled where no model is
   --    named; Lifecycle_Invalid_State, with the state, where one is
   --    already recording or being heard.
   procedure Start (Item : in out Recognizer; Status : out Model_Runner.Errors.Error_Info);

   --  How long the recording under way has run.
   --
   --  @param Item A recognizer.
   --  @return Seconds recorded.
   function Recorded_Seconds (Item : Recognizer) return Duration;

   --  Whether the recording under way has stopped of itself: at the
   --  longest allowed, or because the microphone failed.
   --
   --  @param Item A recognizer.
   --  @return True once it has.
   function Recording_Ended (Item : Recognizer) return Boolean;

   --  Stop recording and hear it.
   --
   --  @param Item A recognizer.
   --  @param Status Success, or Lifecycle_Invalid_State where nothing is
   --    recording.
   procedure Finish (Item : in out Recognizer; Status : out Model_Runner.Errors.Error_Info);

   --  Drop the recording, or stop hearing it. Nothing done where neither
   --  is under way.
   --
   --  @param Item A recognizer.
   procedure Cancel (Item : in out Recognizer);

   --  Whether the recording has been heard, or hearing it failed.
   --
   --  @param Item A recognizer.
   --  @return True when Take has something to give.
   function Has_Result (Item : Recognizer) return Boolean;

   --  What was heard.
   --
   --  @param Item A recognizer with a result.
   --  @param Text The transcript's text; empty on failure or silence.
   --  @param Status Success; or why not -- the microphone's, the model's,
   --    the memory's, Generation_Cancelled.
   --  @param Limit_Reached Whether the recording stopped at the longest
   --    allowed rather than when asked.
   procedure Take
     (Item          : in out Recognizer;
      Text          : out Ada.Strings.Unbounded.Unbounded_String;
      Status        : out Model_Runner.Errors.Error_Info;
      Limit_Reached : out Boolean);

   --  Give the model back now, where it is idle; read again on next use.
   --
   --  @param Item A recognizer.
   --  @param Status Success, or Lifecycle_Invalid_State where it is busy.
   procedure Unload (Item : in out Recognizer; Status : out Model_Runner.Errors.Error_Info);

   --  The memory a model needs read and a session open on it, against
   --  what the host has free: the admission the inference task asks
   --  before it opens a session. Exposed so that it can be tested.
   --
   --  @param Needed Bytes the model and its session take.
   --  @param Available Bytes the host has free.
   --  @param Status Success, or Memory_Limit_Exceeded where Needed and a
   --    margin do not fit.
   procedure Admit
     (Needed    : Interfaces.Unsigned_64;
      Available : Interfaces.Unsigned_64;
      Status    : out Model_Runner.Errors.Error_Info);

private

   type Job is (None, Begin_Recording, Load, Hear, Unload_Model, Quit);

   type Recording_Buffer is access all Model_Runner.Numerics.Real_Array;

   --  What the terminal's calls and the two tasks share.
   protected type Shared is

      procedure Configure (Capacity_Samples : Model_Runner.Numerics.Element_Count);

      function Now return State;
      procedure Set (To : State);

      --  The capture task's work.
      procedure Post_Capture (Work : Job);
      entry Next_Capture (Work : out Job);
      procedure Request_Stop;
      function Stop_Requested return Boolean;
      --  Samples in, at most the room left; Full once there is none.
      procedure Append (Samples : Model_Runner.Numerics.Real_Array; Full : out Boolean);
      procedure Capture_Ended (Outcome : Model_Runner.Errors.Error_Info; At_Limit : Boolean);
      function Capture_Is_Over return Boolean;
      entry Await_Capture (Outcome : out Model_Runner.Errors.Error_Info);
      function Samples_Held return Model_Runner.Numerics.Element_Count;

      --  The inference task's work.
      procedure Post_Inference (Work : Job);
      entry Next_Inference (Work : out Job);

      procedure Set_Result (Text : Ada.Strings.Unbounded.Unbounded_String; Outcome : Model_Runner.Errors.Error_Info);
      function Result_Ready return Boolean;
      procedure Take_Result
        (Text          : out Ada.Strings.Unbounded.Unbounded_String;
         Outcome       : out Model_Runner.Errors.Error_Info;
         Limit_Reached : out Boolean);

      procedure Set_Loaded (Loaded : Boolean);
      function Is_Loaded return Boolean;

      function Buffer return Recording_Buffer;
      procedure Release_Buffer;

   private
      Current_State   : State := Unloaded;
      Capture_Work    : Job := None;
      Inference_Work  : Job := None;
      Stop            : Boolean := False;
      Capture_Over    : Boolean := True;
      Capture_Outcome : Model_Runner.Errors.Error_Info := Model_Runner.Errors.Success;
      At_Limit        : Boolean := False;
      Room            : Recording_Buffer := null;
      Held            : Model_Runner.Numerics.Element_Count := 0;
      Result_Text     : Ada.Strings.Unbounded.Unbounded_String;
      Result_Outcome  : Model_Runner.Errors.Error_Info := Model_Runner.Errors.Success;
      Has_Result      : Boolean := False;
      Loaded          : Boolean := False;
   end Shared;

   task type Capture_Task (Owner : not null access Recognizer);
   task type Inference_Task (Owner : not null access Recognizer);

   type Pool_Access is access Model_Runner.Backend.CPU.Pool;

   type Recognizer is limited record
      Wanted    : Settings;
      Common    : Shared;
      Stop_Hearing : aliased Model_Runner.Cancellation.Token;
      --  The inference task's own.
      Model     : aliased Model_Runner.Whisper.Model;
      Session   : Model_Runner.Whisper.Session;
      Team      : Pool_Access := null;
      Capture   : Capture_Task (Recognizer'Access);
      Inference : Inference_Task (Recognizer'Access);
   end record;

end Model_Runner.Speech;
