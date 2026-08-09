with Interfaces;

with Model_Runner.Backend;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Errors;
with Model_Runner.Sampling;
with Model_Runner.Text;

--  Argument tokenization, parsing and typed command construction.
--
--  Parsing is separated from execution: this package turns an argument vector
--  into a Command value, and nothing downstream ever looks at a raw argument
--  string again. A command that parses is internally consistent, so execution
--  has no option conflicts left to discover.
--
--  Arguments arrive through the Arguments interface rather than from
--  Ada.Command_Line directly, so a test can drive the parser with an exact
--  vector without a process.
--
--  Task safety: parsing is a pure function of the argument vector plus the
--  produced command.
package Model_Runner.CLI.Options is

   --  Source of the argument vector.
   type Arguments is limited interface;

   --  Number of arguments, excluding the program name.
   --
   --  @param Self Argument source.
   --  @return Argument count.
   function Count (Self : Arguments) return Natural is abstract;

   --  One argument.
   --
   --  @param Self Argument source.
   --  @param Index Position in 1 .. Count.
   --  @return Argument text.
   function Value (Self : Arguments; Index : Positive) return String is abstract;

   --  Arguments taken from the process command line.
   type Process_Arguments is limited new Arguments with null record;

   --  Number of process arguments.
   --
   --  @param Self Argument source.
   --  @return Argument count.
   overriding function Count (Self : Process_Arguments) return Natural;

   --  One process argument.
   --
   --  @param Self Argument source.
   --  @param Index Position in 1 .. Count.
   --  @return Argument text.
   overriding function Value
     (Self : Process_Arguments; Index : Positive) return String;

   --  Commands the program accepts. Command names are never localized.
   type Command_Kind is
     (Command_None,
      Command_Run,
      Command_Inspect,
      Command_Help,
      Command_Version);

   --  Where the prompt comes from.
   type Prompt_Source is
     (Prompt_Unset,
      Prompt_Inline,
      Prompt_File,
      Prompt_Standard_Input,
      Prompt_Interactive);

   --  Terminal styling policy.
   type Color_Mode is (Color_Auto, Color_Always, Color_Never);

   --  The name a caller asks for a colour mode by.
   --
   --  Read by the parser and by the message that lists what was expected, so
   --  that neither can offer a mode that is not there. The list used to be
   --  written into the catalog in every locale.
   --
   --  @param Item Mode to name.
   --  @return Lower-case identifier such as "auto".
   function Color_Name (Item : Color_Mode) return String
   is (case Item is
         when Color_Auto   => "auto",
         when Color_Always => "always",
         when Color_Never  => "never");

   --  The colour modes this build accepts, comma-separated.
   --
   --  @return "auto, always, never" and whatever else is added.
   function Color_Names return String;

   --  How much diagnostic output to produce.
   type Verbosity is (Quiet, Normal, Verbose);

   Max_Path : constant := 4096;

   type Text_Access is access String;

   --  A fully validated command.
   --
   --  Owns the heap text it points at; release it with Release.
   type Command is record
      Kind : Command_Kind := Command_None;

      --  Model path, exactly as given. Never resolved against a registry.
      Model_Path : Model_Runner.Text.Bounded;

      --  Topic of a help request, or an empty value for the general help.
      Help_Topic : Model_Runner.Text.Bounded;

      Prompt_Kind : Prompt_Source := Prompt_Unset;
      Prompt_Text : Text_Access := null;
      Prompt_Path : Model_Runner.Text.Bounded;

      System_Text : Text_Access := null;
      System_Path : Model_Runner.Text.Bounded;
      Has_System  : Boolean := False;

      --  Bypass the chat template and tokenize the prompt directly.
      Raw : Boolean := False;

      --  A chat format named on the command line, replacing the model's own.
      --  Empty means the model's template is used.
      Chat_Template : Model_Runner.Text.Bounded;

      Max_Tokens   : Natural := 256;
      Context_Size : Natural := 0;
      Batch_Size   : Natural := 32;

      --  Worker count for matrix-vector products. Zero means "choose from the
      --  processor count"; one means serial execution on the calling task.
      Threads      : Natural := 0;

      --  Which backend evaluates the model. There is one, and naming it is
      --  still worth doing: a name this build does not have is refused by
      --  name rather than running somewhere the caller did not ask for.
      Backend      : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;

      Sampling : Model_Runner.Sampling.Configuration;
      Seed     : Interfaces.Unsigned_64 := 0;
      Has_Seed : Boolean := False;

      Stop_Strings : Model_Runner.Text.Bounded_List (1 .. 16) :=
        [others => Model_Runner.Text.Empty];
      Stop_Count   : Natural := 0;

      Stop_Tokens      : Model_Runner.Text.Number_List (1 .. 64) :=
        [others => 0];
      Stop_Token_Count : Natural := 0;

      Memory_Limit : Interfaces.Unsigned_64 := 0;
      Mapping      : Model_Runner.Byte_Sources.Files.Mapping_Policy :=
        Model_Runner.Byte_Sources.Files.Mapping_Automatic;

      Level      : Verbosity := Normal;
      Show_Stats : Boolean := False;
      Stats_Set  : Boolean := False;
      Color      : Color_Mode := Color_Auto;
      Locale     : Model_Runner.Text.Bounded;

      --  Inspect modes.
      Show_Metadata : Boolean := False;
      Show_Tensors  : Boolean := False;
      Validate_Only : Boolean := False;
   end record;

   --  Release the heap text a command owns. Idempotent.
   --
   --  @param Item Command to release.
   procedure Release (Item : in out Command);

   --  Parse an argument vector into a command.
   --
   --  @param Source Argument vector.
   --  @param Result Typed command; released first.
   --  @param Status Success or a CLI diagnostic naming the offending option.
   procedure Parse
     (Source : Arguments'Class;
      Result : in out Command;
      Status : out Model_Runner.Errors.Error_Info);

   --  Look for --locale before full parsing.
   --
   --  Locale has to be resolved before any diagnostic can be rendered, so a
   --  narrow scan runs first. It reads only the option it is looking for and
   --  reports nothing: a malformed --locale is diagnosed by the full parse.
   --
   --  @param Source Argument vector.
   --  @return Requested locale, or an empty string.
   function Preliminary_Locale (Source : Arguments'Class) return String;

   --  Look for --color before full parsing, for the same reason.
   --
   --  @param Source Argument vector.
   --  @param Found True when the option was present and well formed.
   --  @return Requested mode; Color_Auto when not found.
   function Preliminary_Color
     (Source : Arguments'Class;
      Found  : out Boolean) return Color_Mode;

end Model_Runner.CLI.Options;
