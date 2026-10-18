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
   --  @param Only One task to run, by name -- edit, find or delegate; ""
   --    for all of them.
   --  @param Clean Whether every task ended complete, in every run.
   --  @param Repeats How many times each task is run, each in its project
   --    made afresh; past one, each run's session is kept beside the
   --    project and how many runs of each task ended complete is said.
   --  @param Apart Whether the work is written in a workspace of its own
   --    and taken in once its checks pass there (--isolation workspace).
   --  @param Knowledge Whether what the agents find is kept and told to
   --    later work (--knowledge off turns it off): the same tasks run both
   --    ways set the work figures -- calls before the first change, whole
   --    reads, observations kept -- side by side.
   --  @param Carry Whether a task's later runs keep its project (--carry
   --    on): its sources put back as they were made, its state -- what
   --    earlier runs learned -- kept, and the task made anew in it; so a
   --    second run can be told what the first found, which a project made
   --    afresh each time never is.
   --  @param Max_Seconds How long a task's work may take (--max-seconds):
   --    agents.max_seconds in the project, and the wait for it past that.
   --  @param Context_Size The session's context, in tokens (--context-size):
   --    8192 unless said, so a trial's runs set beside an earlier one's had
   --    the same room; what a reply and its thought may take grow with it.
   procedure Run
     (Model     : String;
      Program   : String;
      Options   : String;
      Only      : String;
      Clean     : out Boolean;
      Repeats   : Positive := 1;
      Apart     : Boolean := False;
      Knowledge : Boolean := True;
      Carry     : Boolean := False;
      Max_Seconds : Positive := 1200;
      Context_Size : Positive := 8192);

end Agent_Trial;
