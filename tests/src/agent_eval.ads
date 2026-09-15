with Model_Runner.Backend;

--  A scored run of the agent loop against a real model.
--
--  The library's agent loop is covered without a model where it can be --
--  the built-in tools answer from their arguments and the call grammar is
--  text in and a grammar out, and both are asserted in the mandatory suite.
--  What that cannot reach is the loop closing: a model reading a task,
--  writing a call the grammar shapes, reading the tool's answer, and saying
--  the thing the answer makes true. That needs weights, and weights are what
--  this command brings.
--
--  It is a campaign like speed and perplexity, gated the same way: it wants
--  a real GGUF and it is slow, so it runs behind --anyway and asks the
--  machine to be quiet first. It is not in the default gate.
--
--  Every task is checkable because every tool is deterministic. A task poses
--  a question the model has to use a tool to answer, the built-in tool
--  answers it the same way on every machine, and a checker reads the final
--  turn for the answer that tool makes true. So a pass is a pass everywhere
--  and a failure is the model's, not the weather's.
package Agent_Eval is

   --  What a run scored.
   type Report is record
      --  Whether the model was there and the machine was quiet enough to run.
      Ran     : Boolean := False;
      Missing : Boolean := False;

      --  Tasks posed and tasks the checker passed.
      Tasks  : Natural := 0;
      Passed : Natural := 0;

      --  Model turns taken and tool calls run, over every task.
      Steps : Natural := 0;
      Calls : Natural := 0;

      --  Tokens the model generated over every task's loop.
      Tokens : Natural := 0;

      --  A line about what happened, for the summary.
      Detail    : String (1 .. 256) := [others => ' '];
      Detail_Up : Natural := 0;

      Load_Before : Long_Float := 0.0;
      Load_After  : Long_Float := 0.0;
   end record;

   --  Run every task against the model at Path.
   --
   --  @param Path The model file. A missing one is reported, not measured.
   --  @param Threads Worker count for the run.
   --  @param Backend Which backend evaluates.
   --  @param Format A built-in chat format to render with -- "qwen3-coder",
   --    "minicpm", and the rest Templates carries -- for a model whose own
   --    template this build will not compile, or one written in a tool shape
   --    that is not the <tool_call> JSON envelope. Empty uses the model's
   --    embedded template. When it is a format whose calls are an XML shape,
   --    a task offering tools reads them in that shape; a task with only an
   --    answer schema stays on the JSON envelope, since that is what its
   --    answer grammar constrains.
   --  @param Anyway Run even when the machine is busy.
   --  @param Waiting Minutes to wait for the machine to quiet, at most.
   --  @param Result What was scored.
   --  @param Trace When set, print each task's transcript -- its turns, the
   --    calls it made, and its final answer -- to standard error, with the
   --    pass or fail and why. It is how a run says which task went wrong and
   --    what it did, rather than only how many passed.
   --  @param Report_Path When not empty, write a JSON report of the run to
   --    this path: the run's totals and, per task, its expectations, its
   --    verdict, and its whole transcript. It is the machine-readable twin
   --    of Trace -- something a later run can be diffed against, or a
   --    dashboard can read -- where Trace is for a person reading along.
   procedure Run
     (Path        : String;
      Threads     : Positive;
      Backend     : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Anyway      : Boolean := False;
      Waiting     : Natural := 0;
      Trace       : Boolean := False;
      Report_Path : String := "";
      Format      : String := "";
      Result      : out Report);

   --  A one-line summary of a report, in the style the other campaigns use.
   --
   --  @param Item The report.
   --  @return "agent-eval: ..." on one line.
   function Summary (Item : Report) return String;

end Agent_Eval;
