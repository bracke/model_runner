with Model_Runner.Errors;
with Model_Runner.Tools.Runner;

--  A runner made of pure tools, for a loop that has to run without one.
--
--  Every tool here answers from its arguments and nothing else: no file is
--  read, no process started, no clock consulted. A call with the same
--  arguments returns the same text on every machine and every run, which is
--  the property an eval needs -- a task is checkable only when the tool's
--  answer is fixed, and a tool that reached the world would not be.
--
--  This is also what keeps the library's promise while closing the loop. The
--  parent starts no process; these tools start none either, so a caller can
--  drive a whole agent loop in-process against them and the promise holds.
--  A tool that reaches the world lives in a caller's own Runner, outside
--  this library, where the promise was always meant to be spent.
--
--  The set is small and deliberate: arithmetic, two string operations and a
--  fixed lookup table. It is enough to pose a task a model has to use a tool
--  to answer, and no larger, because everything here is a thing a test has
--  to keep answering the same way.
package Model_Runner.Tools.Builtin is

   --  The definitions these tools offer, as the JSON array Tools.Read takes.
   --
   --  The same text drives three things: the prompt the template renders
   --  from it, the grammar Tools.Grammar compiles from it, and the answers
   --  Run gives. They cannot drift, because there is one of them.
   --
   --  @return A JSON array of function definitions.
   function Definitions_Text return String;

   --  A runner over the tools above.
   type Instance is new Model_Runner.Tools.Runner.Instance with null record;

   --  Answer one call to a built-in tool.
   --
   --  A call to a tool not in the set, or with an argument it cannot read,
   --  is answered rather than refused: the result says what was wrong, in
   --  words the model reads as the tool's own answer, so the loop goes on
   --  and the model may correct itself. Status fails only when the answer
   --  would not fit the buffer.
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

end Model_Runner.Tools.Builtin;
