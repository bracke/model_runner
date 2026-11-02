with Ada.Finalization;
with Ada.Strings.Unbounded;

with Model_Runner.CLI.Choosers;
with Model_Runner.CLI.Options;
with Model_Runner.Errors;
with Model_Runner.Speech;

--  Speech input in an interactive session: the line editor's dictation,
--  answered by a Model_Runner.Speech recognizer made from the run's
--  options (--speech-model and the rest, or the settings file's).
--
--  Only the harness reaches this. The recognizer it holds owns the speech
--  model and nothing of the conversation's; the editor puts what was heard
--  into the line it is editing, and only the person's Enter sends it.
--
--  The recognizer's tasks are stopped when an Input is closed or goes out
--  of scope, so a session that ends by any road -- /exit, end of input, an
--  exception -- leaves none running.
--
--  Task safety: one task, the terminal's.
package Model_Runner.CLI.Speech_Input is

   type Input is new Ada.Finalization.Limited_Controlled and Model_Runner.CLI.Choosers.Dictation with private;

   --  Make the recognizer where the options name a speech model and do not
   --  turn speech off. Nothing is read or recorded yet.
   --
   --  @param Item The input; closed first.
   --  @param From The run's options.
   procedure Open (Item : in out Input; From : Model_Runner.CLI.Options.Command);

   --  Stop the recognizer and give it back. Idempotent.
   --
   --  @param Item The input.
   procedure Close (Item : in out Input);

   --  @param Item An input.
   --  @return Whether speech is on: a model named and not turned off.
   function Is_Enabled (Item : Input) return Boolean;

   overriding procedure Begin_Dictation (Item : in out Input; Status : out Model_Runner.Errors.Error_Info);
   overriding function Seconds (Item : Input) return Natural;
   overriding function Ended_Itself (Item : Input) return Boolean;
   overriding procedure End_Dictation (Item : in out Input);
   overriding procedure Abandon (Item : in out Input);
   overriding function Is_Done (Item : Input) return Boolean;
   overriding procedure Take
     (Item          : in out Input;
      Text          : out Ada.Strings.Unbounded.Unbounded_String;
      Status        : out Model_Runner.Errors.Error_Info;
      Limit_Reached : out Boolean);

private

   type Input is new Ada.Finalization.Limited_Controlled and Model_Runner.CLI.Choosers.Dictation with record
      Owner : Model_Runner.Speech.Recognizer_Access := null;
   end record;

   overriding procedure Finalize (Item : in out Input);

end Model_Runner.CLI.Speech_Input;
