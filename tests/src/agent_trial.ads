--  A real model given real /work tasks, and how it went.
--
--  The suite cannot script a model's tool calls, and the harness's agent
--  machinery is only ever reached through them: a grammar that cut a value
--  at its first '<', a template's call shape read as JSON, a think block the
--  grammar would not let a reasoning model close -- each passed every unit
--  test and was found by running a model on a task. This is that run made
--  repeatable: for each task, a small Ada project made fresh, a session of
--  the program started on a terminal, the task made, accepted and worked,
--  and what came of it said -- how the task ended, the time, the calls made
--  and which, the work figures the harness records, and what changed.
--
--  It needs a model file and a built program, and runs on the device or the
--  processor as the program chooses; it is run by hand, on small models,
--  and never by the gate.
package Agent_Trial is

   --  Run the trial's tasks with a model.
   --
   --  @param Model The model file.
   --  @param Program The program to run, as built.
   --  @param Options More of the program's options, as one string; "" for
   --    none -- --no-think, among them.
   --  @param Only One task to run, by name; "" for all of them.
   --  @param Clean Whether every task ended complete.
   procedure Run
     (Model   : String;
      Program : String;
      Options : String;
      Only    : String;
      Clean   : out Boolean);

end Agent_Trial;
