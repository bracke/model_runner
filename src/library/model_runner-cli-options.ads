with Interfaces;

with Model_Runner.Backend;
with Model_Runner.Llama;
with Model_Runner.Numerics;
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
      Command_Embed,
      Command_Inspect,
      Command_Help,
      Command_Version);

   --  How the positions of a text are reduced to one vector.
   --
   --  Mean averages every position's hidden state, which is what a text's
   --  embedding usually means: every word contributes. Last takes the final
   --  position alone, which is what a model trained to summarize into its
   --  last token wants. Neither is right for every model, so neither is
   --  chosen on a model's behalf.
   type Pooling_Kind is (Pool_Mean, Pool_Last);

   --  The word a caller types for a pooling.
   --
   --  @param Item Pooling to name.
   --  @return Lower-case identifier.
   function Pooling_Word (Item : Pooling_Kind) return String
   is (case Item is
         when Pool_Mean => "mean",
         when Pool_Last => "last");

   --  The poolings a caller may name, in one line.
   --
   --  @return Comma-separated identifiers, in declaration order.
   function Pooling_Names return String;

   --  Which commands an option belongs to.
   type Command_Set is array (Command_Kind) of Boolean;

   --  How many options the program accepts.
   --
   --  @return The number of entries in the option registry.
   function Option_Count return Natural;

   --  One option's name, with its leading dashes.
   --
   --  @param Index Position, from one.
   --  @return The option name as it is typed.
   function Option_Name (Index : Positive) return String;

   --  The commands that take an option.
   --
   --  @param Index Position, from one.
   --  @return The set of commands it belongs to.
   function Option_Commands (Index : Positive) return Command_Set;

   --  The catalog key suffix that documents an option.
   --
   --  The full key is "help." & command & "." & this, so one option
   --  documented under two commands has a line for each, in each locale.
   --
   --  @param Index Position, from one.
   --  @return The suffix, or an empty string for an option no help lists.
   function Option_Help (Index : Positive) return String;

   --  The word a caller types for a command.
   --
   --  Never localized: it is protocol. A diagnostic naming a translated
   --  command word would tell the reader to type something the parser
   --  refuses.
   --
   --  @param Kind Command to name.
   --  @return The word, or an empty string for no command.
   function Command_Word (Kind : Command_Kind) return String;

   --  The command a word names.
   --
   --  @param Word Word as typed.
   --  @return The command, or Command_None when no command has that word.
   function Command_Of (Word : String) return Command_Kind;

   --  The repacking modes a caller may name, in one line.
   --
   --  @return Comma-separated identifiers, in declaration order.
   function Repack_Names return String;

   --  The cache precisions a caller may name, in one line.
   --
   --  @return Comma-separated identifiers, in declaration order.
   function Cache_Names return String;

   --  Report whether a command takes an option.
   --
   --  Every option used to be accepted by every command: `inspect m.gguf
   --  --temperature 0.5 --interactive` ran the inspection and said nothing,
   --  and thirty-two options were reachable on a command whose help
   --  documents five. A reader who cannot tell a refusal from an
   --  acceptance cannot tell a typo from a setting.
   --
   --  @param Kind Command being parsed.
   --  @param Name Option name, with its dashes.
   --  @return True when that command takes it.
   function Accepts (Kind : Command_Kind; Name : String) return Boolean;

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

   type Text_Access is access String;

   --  How many prompts one command may carry. A caller wanting more than
   --  this is asking for a batch runner, which is a different program.
   Max_Prompts : constant := 16;

   type Prompt_List is array (1 .. Max_Prompts) of Text_Access;

   --  How many adapters one command may stack.
   Max_Adapters : constant := 8;

   type Adapter_List is
     array (1 .. Max_Adapters) of Model_Runner.Text.Bounded;

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

      --  The prompts, in the order they were given. Several are several
      --  sequences from one loaded model: the model is read once and each
      --  prompt gets its own context, which is the whole saving.
      --
      --  Prompt_Text is the first of them, kept because most of the program
      --  wants one prompt and should not have to say which.
      Prompts      : Prompt_List := [others => null];
      Prompt_Count : Natural := 0;
      Prompt_Text  : Text_Access := null;
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

      --  Per-token additions to the logits, as TOKEN=AMOUNT pairs. A short
      --  list because that is what the option is for: nudging a handful of
      --  tokens up or down, not carrying a second copy of the vocabulary.
      Bias_Tokens  : Model_Runner.Text.Number_List (1 .. 64) := [others => 0];
      Bias_Amounts : Model_Runner.Numerics.Real_List (1 .. 64) :=
        [others => 0.0];
      Bias_Count   : Natural := 0;

      --  How many alternatives to report for each generated token, or zero
      --  for none.
      Logprobs : Natural := 0;

      --  How many of the oldest positions to drop when the context fills,
      --  and how many at the front to keep when that happens.
      Context_Shift : Natural := 0;
      Context_Keep  : Natural := 1;

      --  A smaller model to propose tokens for the real one to check, and
      --  how many it may propose at a time.
      Draft_Path   : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Draft_Tokens : Natural := 4;

      --  Whether the caller named the count. A count without a draft model
      --  is an option that cannot do anything, and saying so beats leaving
      --  it to be discovered.
      Draft_Tokens_Set : Boolean := False;

      Memory_Limit : Interfaces.Unsigned_64 := 0;

      --  Bytes of device memory the model's matrices may take, and whether
      --  the caller said so. Zero and False leave the choice to the device:
      --  a share of the heap it reports, and a refusal for a model larger
      --  than that share. A caller who names a number has been told what
      --  the device has and means it, so the refusal becomes a note and the
      --  run goes ahead with whatever giving-back that implies.
      Device_Memory     : Interfaces.Unsigned_64 := 0;
      Device_Memory_Set : Boolean := False;

      --  Zero bytes of the device's own memory, which means the weights are
      --  read where they lie rather than copied anywhere.
      Device_Share      : Boolean := False;

      --  How long to wait for one product before giving up on the device,
      --  in seconds. The default is a minute, which is far longer than any
      --  product on any machine this has run on and is a bound rather than
      --  a wait: a device that has stopped answering gives the caller back
      --  its thread instead of keeping it forever.
      --
      --  Said on the command line because the bound is a guess about
      --  hardware, and a guess about hardware is exactly what a caller with
      --  different hardware needs to be able to correct. A model wide
      --  enough, on a device slow enough, can take longer than a minute for
      --  one product, and before this that caller had no way to say so.
      --
      --  How often the wait asks whether the caller wants to stop is not
      --  said here and stays at twenty milliseconds. That is a
      --  responsiveness number rather than a hardware one -- it decides how
      --  quickly a Ctrl-C is noticed, and no person notices the difference
      --  between twenty milliseconds and five.
      Device_Patience     : Duration := 60.0;
      Device_Patience_Set : Boolean := False;

      --  Which of the host's devices to compute on, counting from one in the
      --  order `inspect` lists them. A machine with one device has nothing
      --  to choose and the default chooses it; a machine with an integrated
      --  device beside a discrete one has a reason to say which, and before
      --  this there was no way to.
      Device_Index        : Positive := 1;
      Device_Index_Set    : Boolean := False;
      Mapping      : Model_Runner.Byte_Sources.Files.Mapping_Policy :=
        Model_Runner.Byte_Sources.Files.Mapping_Automatic;

      Level      : Verbosity := Normal;
      Show_Stats : Boolean := False;
      Stats_Set  : Boolean := False;
      Color      : Color_Mode := Color_Auto;

      --  What to decode the weight matrices into at load, if anything.
      Repack     : Model_Runner.Llama.Repack_Mode :=
        Model_Runner.Llama.No_Repack;

      --  How the session stores what it has committed. The default is the
      --  precision the engine computes in, which is what every published
      --  figure was measured against.
      Cache      : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Exact;

      --  How an embedding reduces the positions of its text, and whether
      --  the result is scaled to unit length. Unit length is the default
      --  because the usual thing to do with two embeddings is compare their
      --  directions, and a comparison of directions is a dot product only
      --  when both have length one.
      --  A grammar the generated text must obey, as text or as a path to a
      --  file holding it. Empty for neither, and naming both is a usage
      --  error rather than a precedence rule nobody would remember.
      --  A low-rank adapter to merge into the weights before generating,
      --  and what to scale its difference by. An adapter needs the weights
      --  as binary32, so naming one selects that repacking when the caller
      --  named none, and naming brain floats beside it is a usage error
      --  rather than a quiet rounding of every merged weight.
      --  A saved session to fill the cache from before the prompt is read,
      --  and one to write it to when the run is done. Either may be given
      --  without the other: reading a document once and saving it, then
      --  asking about it many times, is the shape this is for.
      Load_Session : Model_Runner.Text.Bounded;
      Save_Session : Model_Runner.Text.Bounded;

      --  The adapters, in the order they were given, and what to multiply
      --  each one's difference by. They are merged in that order, which is
      --  the order they were trained to be applied in; a merge is an
      --  addition, so a later one does not undo an earlier one -- and a
      --  scale of minus one does exactly that, which is how an adapter comes
      --  off again.
      Adapters       : Adapter_List := [others => Model_Runner.Text.Empty];
      Adapter_Scales : Model_Runner.Numerics.Real_List (1 .. Max_Adapters) :=
        [others => 1.0];
      Adapter_Count  : Natural := 0;
      Scale_Count    : Natural := 0;

      --  The first of them, kept because the parts of the program that ask
      --  whether there is an adapter at all should not have to count.
      Adapter_Path  : Model_Runner.Text.Bounded;
      Adapter_Scale : Model_Runner.Numerics.Real := 1.0;

      --  A JSON schema, which becomes a grammar before anything is
      --  generated. Held apart from the grammar so that a caller naming both
      --  is refused rather than silently given one of them.
      Schema_Text : Text_Access := null;
      Schema_Path : Model_Runner.Text.Bounded;

      Grammar_Text : Text_Access := null;
      Grammar_Path : Model_Runner.Text.Bounded;

      Pooling    : Pooling_Kind := Pool_Mean;
      Normalize  : Boolean := True;
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
