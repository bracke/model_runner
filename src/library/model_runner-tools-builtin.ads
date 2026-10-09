with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Tools.Runner;
with Model_Runner.Tools.Schemas;

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

   --  How a sub-agent's run ended. Completed: it answered, and its answer
   --  is the result. Failed: it could not go on -- a render, a generation,
   --  a grammar failed, or it went round in circles. Cancelled: the run it
   --  belongs to was. Exhausted: a budget ran out -- steps, tokens, time --
   --  before it answered. Only Completed is a result; what a sub-agent said
   --  before it stopped any other way is not its answer.
   type Sub_State is (Completed, Failed, Cancelled, Exhausted);

   --  A sub-agent's run, beside its answer: how it ended, why in words,
   --  and what it took.
   type Sub_Outcome is record
      State   : Sub_State := Failed;
      Reason  : Ada.Strings.Unbounded.Unbounded_String;
      Timed   : Boolean := False;
      Steps   : Natural := 0;
      Calls   : Natural := 0;
      Tokens  : Natural := 0;
   end record;

   --  Run Instruction as a subtask and return the sub-agent's final answer.
   --
   --  @param Self The delegator.
   --  @param Instruction The subtask, in the words the sub-agent is given as
   --    its task.
   --  @param Context What the calling run has left -- its cancellation, its
   --    deadline, its tokens -- which the sub-agent runs within: a child's
   --    budget is the least of its own and its parent's.
   --  @param Result Buffer receiving the sub-agent's answer from its first
   --    index, written only when it completed.
   --  @param Last The index of the last byte written, as a runner's Last
   --    is; Result'First - 1 when none was.
   --  @param Ended How the sub-agent's run ended; Timed says a budget of
   --    time was the one that ran out.
   --  @param Status Success, or a diagnostic when the subtask could not run.
   procedure Run_Sub
     (Self        : in out Delegator;
      Instruction : String;
      Context     : Model_Runner.Tools.Runner.Tool_Context;
      Result      : out String;
      Last        : out Natural;
      Ended       : out Sub_Outcome;
      Status      : out Model_Runner.Errors.Error_Info) is abstract;

   --  Whether two delegated subtasks may run at the same time. Delegation
   --  runs each sub-agent on a session of its own; a delegator with more than
   --  one such session, on a backend that evaluates two at once, says True,
   --  and the delegate tool is then parallel-safe (see Instance's
   --  Parallel_Safe). The default is False: one subtask at a time.
   --
   --  @param Self The delegator.
   --  @return Whether two subtasks may overlap.
   function Parallel_Delegates (Self : Delegator) return Boolean is abstract;

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

   --  Back this runner's memory with a file, so what memory_put writes
   --  outlives the run: the notes already in the file are read in now, and
   --  each later memory_put writes the whole set back. Passing an empty path
   --  (the default state) keeps memory in this runner alone, gone when it is.
   --  The file is this runner's own -- two runs sharing one, or a fanned-out
   --  sub-agent sharing the caller's, would race on it -- so the caller gives
   --  it only to a runner whose memory calls do not overlap.
   --
   --  @param Self The runner.
   --  @param Path The file to keep the notes in, or "" for memory in this
   --    runner alone.
   procedure Use_Memory_File
     (Self : in out Instance; Path : String);

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
   --  A string argument of a call, decoded from its JSON.
   --
   --  @param Args The call's arguments, a JSON object.
   --  @param Key The argument's name.
   --  @param Found Whether it was there as a string.
   --  @return Its content, or "" when not Found.
   function Text_Argument (Args : String; Key : String; Found : out Boolean)
     return String;

   --  A list-of-strings argument of a call, each decoded from its JSON.
   --
   --  @param Args The call's arguments, a JSON object.
   --  @param Key The argument's name.
   --  @param Items Its strings, in order; empty when it is not there.
   --  @param Found Whether it was there.
   --  @param Well_Formed False when it was there and was not a JSON array
   --    of strings -- a list written as one string among them, which is
   --    then not guessed at.
   procedure Text_List_Argument
     (Args        : String;
      Key         : String;
      Items       : out Schemas.Choice_Lists.Vector;
      Found       : out Boolean;
      Well_Formed : out Boolean);

   --  The tools this runner can carry out as it is wired: every built-in
   --  one, but delegate only where it has a delegator and ask_user only
   --  where it has somebody to ask. A tool the model is shown is one its
   --  call can run -- a model told of a tool the runner will decline spends
   --  its tokens choosing it.
   --
   --  @param Self The runner.
   --  @return A JSON array of function definitions.
   function Offered_Text (Self : Instance) return String;

   overriding procedure Run
     (Self      : in out Instance;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Outcome   : out Model_Runner.Tools.Runner.Call_Outcome;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Name the directory the file tools work in: a relative path a call
   --  gives is under it, said to the model as it gave it. Without one they
   --  work in the process's own, as a person's run does; a project's work
   --  names the project, so what it reaches is not whatever directory the
   --  process happens to be in.
   --
   --  @param Self The runner.
   --  @param Base The directory, absolute; "" for the process's own.
   procedure Set_Base (Self : in out Instance; Base : String);

   --  The directory the file tools work in, as Set_Base named it; "" for
   --  the process's own.
   --
   --  @param Self The runner.
   --  @return The directory.
   function Base (Self : Instance) return String;

   --  What each built-in tool does to the state later calls read, as the
   --  registry describes it (Registry.Kind_Of).
   overriding function Kind
     (Self : Instance; Named : String) return Model_Runner.Tools.Runner.Call_Kind;

   --  What each built-in tool reads or changes, as the registry describes
   --  it (Registry.Touches).
   overriding function Touches
     (Self : Instance; Named : String) return Model_Runner.Tools.Runner.Resource;

   --  What a call reading the tree read, as it is now: a file it names by
   --  its contents' revision, and a folder or the whole tree -- a search,
   --  the graph, the checks -- by every file's name, size and time under
   --  it, the folders that start with a dot left out. "" for a call that
   --  reads no files.
   overriding function Stamp
     (Self : Instance; Named : String; Arguments : String) return String;

   --  Which built-in tools are safe to run beside another call in the turn:
   --  those the registry marks so (Registry.Parallel), narrowed by what this
   --  runner holds -- retrieve only while it ranks by words alone, the one
   --  embedding session being shared, and delegate only where its delegator
   --  can run two subtasks at once.
   overriding function Parallel_Safe
     (Self : Instance; Named : String) return Boolean;

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

      --  The directory a relative path a file tool is given is under; ""
      --  for the process's own.
      Base   : Ada.Strings.Unbounded.Unbounded_String;

      --  What retrieve embeds with, or null to rank by words alone.
      Embed  : Embedder_Reference := null;

      --  What delegate runs a subtask with, or null to decline delegation.
      Sub    : Delegator_Reference := null;

      --  What ask_user asks through, or null to decline the question.
      Asker  : Inquirer_Reference := null;

      --  The file the notes are kept in, or empty for memory in this runner
      --  alone. When set, memory_put writes the whole set back after a change.
      Store  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Model_Runner.Tools.Builtin;
