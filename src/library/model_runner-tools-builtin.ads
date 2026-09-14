private with Ada.Strings.Unbounded;

with Model_Runner.Errors;
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

   --  A runner over the built-in tools. It carries the scratchpad the memory
   --  tools write and read, so a call to remember something is seen by a
   --  later call to recall it, for the life of this runner.
   type Instance is new Model_Runner.Tools.Runner.Instance with private;

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
   end record;

end Model_Runner.Tools.Builtin;
