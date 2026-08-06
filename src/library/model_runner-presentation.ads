with Model_Runner.CLI.Options;
with Model_Runner.Errors;
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
--  Task safety: a Console is used by one task.
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

   --  Write a heading to standard error.
   --
   --  @param Item Console to write through.
   --  @param Key Stable message identifier of the heading.
   procedure Put_Heading (Item : in out Console; Key : String);

   --  Write a labelled value to standard error.
   --
   --  The label is localized; the value is not, because it is data.
   --
   --  @param Item Console to write through.
   --  @param Key Stable message identifier of the label.
   --  @param Value Value text, already escaped when it came from a model file.
   procedure Put_Field
     (Item  : in out Console;
      Key   : String;
      Value : String);

   --  Write a labelled value whose label is data rather than a message.
   --
   --  A metadata key comes from the model file, so unlike Put_Field's label it
   --  is not localized and is untrusted: escape it as you would any other
   --  text a file supplied.
   --
   --  @param Item Console to write through.
   --  @param Label Label text, already escaped.
   --  @param Value Value text, already escaped.
   procedure Put_Data_Field
     (Item  : in out Console;
      Label : String;
      Value : String);

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
   --  @param Item Console to write through.
   --  @param Key Stable message identifier.
   procedure Put_Option (Item : in out Console; Key : String);

   --  Report generation statistics on standard error.
   --
   --  @param Item Console to write through.
   --  @param Outcome Generation result to summarize.
   procedure Put_Statistics
     (Item    : in out Console;
      Outcome : Model_Runner.Generation.Result);

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
      Progress_Open : Boolean := False;
   end record;

   type Standard_Output_Sink is limited new Model_Runner.Output.Sink with record
      Closed : Boolean := False;
   end record;

   type Progress_Reporter (Owner : access Console)
   is limited new Model_Runner.Progress.Observer with null record;

end Model_Runner.Presentation;
