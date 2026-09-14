private with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Tools.Runner;

--  The runner of the built-in tools.
--
--  There are two sets. The pure set -- arithmetic, two string operations and
--  a fixed lookup -- answers from its arguments and nothing else: same
--  arguments, same answer, on every machine and every run. That is what the
--  eval needs, so `Definitions_Text` offers exactly those four and the eval
--  scores against them.
--
--  The full set adds tools that reach the world: a scratchpad the model
--  writes and reads, base64, the clock, files, a shell, a Python
--  interpreter, an HTTP fetch, a web search and SQLite. These do start
--  processes, open files and read the clock -- so this package no longer
--  keeps the "starts no process, opens no socket" promise the rest of the
--  library keeps, and the ones that reach the network or a database do it by
--  running `curl`, `python3`, `sqlite3` or `sh`, and say so plainly when
--  that program is not on the machine. `All_Definitions_Text` offers the
--  whole set, and `model_runner run --agent` uses it; the eval does not,
--  because a shell or a fetch is not a thing a test can keep answering the
--  same way.
package Model_Runner.Tools.Builtin is

   --  The pure tools' definitions, as the JSON array Tools.Read takes. The
   --  same text drives the prompt, the grammar, and the answers, so they
   --  cannot drift. The eval offers these.
   --
   --  @return A JSON array of function definitions.
   function Definitions_Text return String;

   --  Every built-in tool's definitions, pure and impure alike. What
   --  `run --agent` offers.
   --
   --  @return A JSON array of function definitions.
   function All_Definitions_Text return String;

   --  Something that turns a text into one vector, for the retrieve tool's
   --  semantic ranking. A caller that has a model loaded supplies one (see
   --  Use_Embedder); with it, retrieve ranks a folder's passages by how close
   --  their meaning is to the query rather than by the words they share.
   --  Without one, retrieve ranks by words alone.
   --
   --  The vector is unit length, so the similarity of two texts is the dot
   --  product of their vectors.
   type Embedder is limited interface;

   --  Reduce Text to one unit-length vector.
   --
   --  @param Self The embedder.
   --  @param Text The text to embed.
   --  @param Vector Receives the vector in 0 .. Last; must be at least the
   --    model's embedding width wide, or Status fails.
   --  @param Last The last index written -- the embedding width minus one.
   --  @param Status Success, or a diagnostic when the text cannot be embedded
   --    or the buffer is too small.
   procedure Embed
     (Self   : in out Embedder;
      Text   : String;
      Vector : out Model_Runner.Numerics.Real_Array;
      Last   : out Natural;
      Status : out Model_Runner.Errors.Error_Info) is abstract;

   --  A reference to whatever embeds for the retrieve tool.
   type Embedder_Reference is access all Embedder'Class;

   --  Something that runs one self-contained subtask on a fresh agent loop of
   --  its own and hands back its answer, for the delegate tool. A caller that
   --  has a model loaded supplies one (see Use_Delegator); with it, the model
   --  can split a large job into pieces, each run by a sub-agent with its own
   --  budget and its own conversation, so the detail of a piece never fills
   --  the caller's own context -- only the answer comes back.
   --
   --  The sub-agent runs on a session of its own, so the caller's loop is not
   --  disturbed, and it is itself given no delegator, so delegation cannot
   --  recurse without bound: a sub-agent's own delegate call is declined.
   type Delegator is limited interface;

   --  Run Instruction as a subtask and return the sub-agent's final answer.
   --
   --  @param Self The delegator.
   --  @param Instruction The subtask, in the words the sub-agent is given as
   --    its task.
   --  @param Result Buffer receiving the sub-agent's answer.
   --  @param Last Number of bytes written.
   --  @param Status Success, or a diagnostic when the subtask could not run.
   procedure Run_Sub
     (Self        : in out Delegator;
      Instruction : String;
      Result      : out String;
      Last        : out Natural;
      Status      : out Model_Runner.Errors.Error_Info) is abstract;

   --  A reference to whatever runs a delegated subtask.
   type Delegator_Reference is access all Delegator'Class;

   --  Something that puts a question to the user and returns their answer,
   --  for the ask_user tool. A caller with a console supplies one (see
   --  Use_Inquirer); with it, the model can pause mid-loop to ask for what
   --  only the user knows -- a missing detail, a choice, a go-ahead -- and
   --  carry on with the answer. Without one, ask_user declines, so a run with
   --  no one to ask (an eval, a library embedding) does not block.
   type Inquirer is limited interface;

   --  Put Question to the user and return their answer.
   --
   --  @param Self The inquirer.
   --  @param Question The question, in the words the user is shown.
   --  @param Answer Buffer receiving the user's answer.
   --  @param Last Number of bytes written.
   --  @param Status Success, or a diagnostic when no answer can be had.
   procedure Ask
     (Self     : in out Inquirer;
      Question : String;
      Answer   : out String;
      Last     : out Natural;
      Status   : out Model_Runner.Errors.Error_Info) is abstract;

   --  A reference to whatever asks the user a question.
   type Inquirer_Reference is access all Inquirer'Class;

   --  A runner over the built-in tools. It carries the scratchpad the memory
   --  tools write and read, so a call to remember something is seen by a
   --  later call to recall it, for the life of this runner.
   type Instance is new Model_Runner.Tools.Runner.Instance with private;

   --  Give this runner an embedder, so its retrieve tool ranks by meaning.
   --  Passing null (the default state) leaves retrieve ranking by words.
   --
   --  @param Self The runner.
   --  @param Source What retrieve will embed with, or null.
   procedure Use_Embedder
     (Self : in out Instance; Source : Embedder_Reference);

   --  Give this runner a delegator, so its delegate tool runs a subtask on a
   --  sub-agent. Passing null (the default state) leaves delegate declining,
   --  which is also how a sub-agent's own runner is left, so delegation does
   --  not recurse without bound.
   --
   --  @param Self The runner.
   --  @param Source What delegate will run a subtask with, or null.
   procedure Use_Delegator
     (Self : in out Instance; Source : Delegator_Reference);

   --  Give this runner an inquirer, so its ask_user tool can put a question
   --  to the user. Passing null (the default state) leaves ask_user declining,
   --  so a run with no one to ask does not block.
   --
   --  @param Self The runner.
   --  @param Source What ask_user will ask through, or null.
   procedure Use_Inquirer
     (Self : in out Instance; Source : Inquirer_Reference);

   --  Answer one call to a built-in tool.
   --
   --  A call to a tool not in the set, or with an argument it cannot read,
   --  is answered rather than refused: the result says what was wrong, in
   --  words the model reads as the tool's own answer, so the loop goes on
   --  and the model may correct itself. A tool that reaches the world and
   --  fails -- a missing file, a command that is not installed -- answers
   --  the same way, with an error the model can read. Status fails only when
   --  the answer would not fit the buffer.
   --
   --  @param Self The runner.
   --  @param Named The function called.
   --  @param Arguments The arguments, as one line of JSON.
   --  @param Result Buffer receiving the answer.
   --  @param Last Number of bytes written.
   --  @param Status Success or Tools_Too_Large.
   overriding procedure Run
     (Self      : in out Instance;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Status    : out Model_Runner.Errors.Error_Info);

private

   --  The scratchpad: a bounded set of key-value notes the memory tools
   --  keep. Small on purpose -- a model's working memory, not a store.
   Max_Notes : constant := 64;

   type Note is record
      Key   : Ada.Strings.Unbounded.Unbounded_String;
      Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Notes is array (1 .. Max_Notes) of Note;

   type Instance is new Model_Runner.Tools.Runner.Instance with record
      Memory : Notes;
      Used   : Natural := 0;

      --  What retrieve embeds with, or null to rank by words alone.
      Embed  : Embedder_Reference := null;

      --  What delegate runs a subtask with, or null to decline delegation.
      Sub    : Delegator_Reference := null;

      --  What ask_user asks through, or null to decline the question.
      Asker  : Inquirer_Reference := null;
   end record;

end Model_Runner.Tools.Builtin;
