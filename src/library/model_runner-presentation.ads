with Model_Runner.CLI.Options;
with Model_Runner.Errors;
with Interfaces;

with Model_Runner.Generation;
with Model_Runner.Localization;
with Model_Runner.Output;
with Model_Runner.Progress;

--  Terminal presentation.
--
--  This is the only package that writes to standard output or standard error,
--  and the only one that uses terminal styling. Everything below it reports
--  structured values.
--
--  Stream discipline
--
--    generated model text   standard output, unchanged
--    help and version       standard output
--    diagnostics, warnings  standard error
--    progress, statistics   standard error
--    interactive prompts    standard error, so a redirected standard output
--                           receives only generated text
--
--  So `model_runner run m.gguf --prompt-file p.txt > answer.txt` puts only
--  generated text in answer.txt.
--
--  Styling. Roles, headings and diagnostic prefixes may be styled; generated
--  model text never is. Severity is always carried by a word as well as a
--  colour, so output stays meaningful when styling is off. Automatic mode is
--  decided per destination, so a piped standard output and a terminal standard
--  error behave correctly at the same time.
--
--  Task safety: a Console is used by one task. Open also writes the
--  colour policy of `terminal_styles`, which is global to the process; it
--  writes the same value every time, so consoles do not contend, but a
--  caller with a policy of its own does lose it.
package Model_Runner.Presentation is

   --  Capabilities of the destinations, so tests can substitute a terminal
   --  that is not there.
   type Terminal_Capabilities is record
      Output_Is_Terminal : Boolean := False;
      Error_Is_Terminal  : Boolean := False;
      Input_Is_Terminal  : Boolean := False;
      Colour_Suppressed  : Boolean := False;
   end record;

   --  Report whether an interactive session is possible on these
   --  destinations.
   --
   --  Both standard input and standard output must be terminals. Without the
   --  first there is nothing to read from and the session consumes a file as
   --  though someone were typing it; without the second it draws prompts into
   --  whatever the output was redirected to.
   --
   --  @param Item Capabilities of the destinations.
   --  @return True when an interactive session can be held.
   function Supports_Interaction (Item : Terminal_Capabilities) return Boolean
   is (Item.Input_Is_Terminal and then Item.Output_Is_Terminal);

   --  Presentation state: the catalog, the styling policy and the destination
   --  capabilities.
   type Console is tagged limited private;

   --  Prepare a console.
   --
   --  Sets the colour policy of `terminal_styles` to always, which is
   --  process-global state and not this console's. It is deliberate: that
   --  library gates styling on a policy of its own, judged by whether
   --  standard output is a terminal, and a global judged by one stream
   --  cannot answer a question asked per stream. This console has the mode,
   --  the destination and NO_COLOR in hand and decides for itself, so the
   --  library is told to emit what it is asked for.
   --
   --  What that costs a caller: a program embedding this engine and also
   --  using `terminal_styles` directly will find its own colour policy
   --  replaced. Set it again after opening a console if you rely on it.
   --
   --  @param Item Console to prepare.
   --  @param Catalog Resolved message catalog.
   --  @param Mode Requested styling policy.
   --  @param Capabilities Destination capabilities.
   --  @param Level Diagnostic verbosity.
   procedure Open
     (Item         : in out Console;
      Catalog      : access constant Model_Runner.Localization.Catalog;
      Mode         : Model_Runner.CLI.Options.Color_Mode;
      Capabilities : Terminal_Capabilities;
      Level        : Model_Runner.CLI.Options.Verbosity);

   --  Report whether styling applies to standard error.
   --
   --  @param Item Console to inspect.
   --  @return True when diagnostics may carry escape sequences.
   function Styles_Diagnostics (Item : Console) return Boolean;

   --  Write a line of application text to standard output.
   --
   --  Used for help and version output, never for generated model text.
   --
   --  @param Item Console to write through.
   --  @param Text Line to write.
   procedure Put_Line (Item : in out Console; Text : String);

   --  Write a localized line to standard output.
   --
   --  @param Item Console to write through.
   --  @param Key Stable message identifier.
   --  @param Arguments Message arguments.
   procedure Put_Message
     (Item      : in out Console;
      Key       : String;
      Arguments : Model_Runner.Localization.Argument_List :=
        Model_Runner.Localization.Empty_Arguments);

   --  Look up a localized value for embedding in a field.
   --
   --  @param Item Console to read through.
   --  @param Key Stable message identifier.
   --  @return Rendered text.
   function Message_Value (Item : Console; Key : String) return String;

   --  Which stream a line belongs on.
   --
   --  An answer is what the command was asked for, and belongs on standard
   --  output where a caller can redirect it. Everything else -- diagnostics,
   --  warnings, progress, statistics, and the responses interactive mode
   --  gives its own commands -- belongs on standard error, so that
   --  redirecting the answer does not collect them.
   --
   --  Headings and fields carry both kinds: an inspection report is an
   --  answer, the statistics after a run are not, and they are written by
   --  the same two operations. There is no default, because the whole of the
   --  inspection report went to standard error for as long as there was one
   --  -- `inspect MODEL > report.txt` wrote an empty file -- and it did that
   --  by inheriting a destination nobody at the call site had to think about.
   type Destination is (Answer, Diagnostic);

   --  Write a heading.
   --
   --  @param Item Console to write through.
   --  @param Key Stable message identifier of the heading.
   --  @param Where Which stream the heading belongs on.
   procedure Put_Heading
     (Item  : in out Console;
      Key   : String;
      Where : Destination);

   --  Write a labelled value.
   --
   --  The label is localized; the value is not, because it is data.
   --
   --  @param Item Console to write through.
   --  @param Key Stable message identifier of the label.
   --  @param Value Value text, already escaped when it came from a model file.
   --  @param Where Which stream the line belongs on.
   procedure Put_Field
     (Item  : in out Console;
      Key   : String;
      Value : String;
      Where : Destination);

   --  Write a labelled value whose label is data rather than a message.
   --
   --  A metadata key comes from the model file, so unlike Put_Field's label it
   --  is not localized and is untrusted: escape it as you would any other
   --  text a file supplied.
   --
   --  @param Item Console to write through.
   --  @param Label Label text, already escaped.
   --  @param Value Value text, already escaped.
   --  @param Where Which stream the line belongs on.
   procedure Put_Data_Field
     (Item  : in out Console;
      Label : String;
      Value : String;
      Where : Destination);

   --  Report a structured condition on standard error.
   --
   --  Emits the severity word, the public diagnostic code and the localized
   --  description. Context frames and the file offset are added only in
   --  verbose mode. Prompt text, system messages and generated output are
   --  never included.
   --
   --  @param Item Console to write through.
   --  @param Condition Condition to report.
   procedure Report
     (Item      : in out Console;
      Condition : Model_Runner.Errors.Error_Info);

   --  Report a localized warning on standard error.
   --
   --  @param Item Console to write through.
   --  @param Key Stable message identifier.
   --  @param Arguments Message arguments.
   procedure Warn
     (Item      : in out Console;
      Key       : String;
      Arguments : Model_Runner.Localization.Argument_List :=
        Model_Runner.Localization.Empty_Arguments);

   --  Write a localized note to standard error, with no severity prefix.
   --
   --  Used for usage hints and interactive responses, which are neither
   --  diagnostics nor generated text.
   --
   --  @param Item Console to write through.
   --  @param Key Stable message identifier.
   --  @param Arguments Message arguments.
   procedure Put_Note
     (Item      : in out Console;
      Key       : String;
      Arguments : Model_Runner.Localization.Argument_List :=
        Model_Runner.Localization.Empty_Arguments);

   --  Write an interactive prompt marker to standard error without a line
   --  break, so that the user types on the same line.
   --
   --  @param Item Console to write through.
   --  @param Key Stable message identifier of the marker.
   procedure Put_Prompt (Item : in out Console; Key : String);

   --  Write an indented help line to standard output.
   --
   --  Indentation is layout, so it lives here rather than inside a translated
   --  string where it could be lost or reflowed.
   --
   --  A help line that carries a value -- the backends this build has, the
   --  chat formats it knows, the colour modes it takes -- goes through here
   --  too. It did not, once: three such lines were printed with Put_Message
   --  instead, one at a time, and each lost its indentation and its place in
   --  the list because that is what the two calls differ in.
   --
   --  @param Item Console to write through.
   --  @param Key Stable message identifier.
   --  @param Arguments Named arguments the line may reference.
   procedure Put_Option
     (Item      : in out Console;
      Key       : String;
      Arguments : Model_Runner.Localization.Argument_List :=
        Model_Runner.Localization.Empty_Arguments);

   --  Report generation statistics on standard error.
   --
   --  @param Item Console to write through.
   --  @param Outcome Generation result to summarize.
   --  @param Device Name of the device the run used, or empty for a run that
   --    used none. The three fields after it are reported only when it is
   --    given, because they are answers to a question a run on the processor
   --    is not asked.
   --  @param Resident How many of the model's matrices the device holds.
   --  @param Resident_Bytes How many bytes those take.
   --  @param Given_Back How many matrices were released to make room for
   --    others. Anything above zero says the model does not fit and is being
   --    uploaded again as it is wanted, which is the difference between a
   --    device that is computing and one that is being fed.
   procedure Put_Statistics
     (Item           : in out Console;
      Outcome        : Model_Runner.Generation.Result;
      Device         : String := "";
      Resident       : Natural := 0;
      Resident_Bytes : Interfaces.Unsigned_64 := 0;
      Given_Back     : Natural := 0);

   --  A sink that writes generated text to standard output.
   --
   --  Text is written exactly as received. Closure of the destination -- a
   --  broken pipe -- is reported through the Closed flag rather than raised,
   --  so it becomes the completion reason Output_Closed.
   type Standard_Output_Sink is limited new Model_Runner.Output.Sink
   with private;

   --  Write generated text.
   --
   --  @param Self Sink instance.
   --  @param Item Text to write, unchanged.
   --  @param Closed True once the destination has gone away.
   overriding procedure Write
     (Self   : in out Standard_Output_Sink;
      Item   : String;
      Closed : out Boolean);

   --  Flush buffered output.
   --
   --  @param Self Sink instance.
   --  @param Closed True once the destination has gone away.
   overriding procedure Flush
     (Self : in out Standard_Output_Sink; Closed : out Boolean);

   --  Report whether the destination has closed.
   --
   --  @param Self Sink instance.
   --  @return True once closure was observed.
   overriding function Is_Closed (Self : Standard_Output_Sink) return Boolean;

   --  A progress observer that writes to standard error.
   --
   --  Progress is suppressed on a non-terminal destination unless verbose mode
   --  asks for it, and every progress line is finished before a diagnostic is
   --  written, so the two never interleave.
   type Progress_Reporter (Owner : access Console)
   is limited new Model_Runner.Progress.Observer with private;

   --  Handle a progress event.
   --
   --  @param Self Observer instance.
   --  @param Item Event to display or discard.
   overriding procedure Notify
     (Self : in out Progress_Reporter;
      Item : Model_Runner.Progress.Event);

private

   type Console is tagged limited record
      Catalog       : access constant Model_Runner.Localization.Catalog := null;
      Mode          : Model_Runner.CLI.Options.Color_Mode :=
        Model_Runner.CLI.Options.Color_Auto;
      Capabilities  : Terminal_Capabilities;
      Level         : Model_Runner.CLI.Options.Verbosity :=
        Model_Runner.CLI.Options.Normal;
   end record;

   type Standard_Output_Sink is limited new Model_Runner.Output.Sink with record
      Closed : Boolean := False;
   end record;

   type Progress_Reporter (Owner : access Console)
   is limited new Model_Runner.Progress.Observer with null record;

end Model_Runner.Presentation;
