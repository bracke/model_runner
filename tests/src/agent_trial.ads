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
with Ada.Strings.Unbounded;
with Hostkit;

package Agent_Trial is

   --  A campaign consumes these records rather than interpreting terminal output.
   --  Metrics not reported by the harness remain -1, distinct from a measured zero.
   type Verdict is (Passed, Failed, Ungraded, Infrastructure_Error);
   type Attempt is record
      Task_Name       : Ada.Strings.Unbounded.Unbounded_String;
      Ending          : Ada.Strings.Unbounded.Unbounded_String;
      Directory       : Ada.Strings.Unbounded.Unbounded_String;
      Figures         : Ada.Strings.Unbounded.Unbounded_String;
      Grade           : Verdict := Infrastructure_Error;
      Seconds         : Duration := -1.0;
      Work_Seconds    : Duration := -1.0;
      Load_Seconds    : Duration := -1.0;
      Calls           : Natural := 0;
      Executed_Calls  : Long_Long_Integer := -1;
      Generated_Tokens : Long_Long_Integer := -1;
      Root_Tokens     : Long_Long_Integer := -1;
      Delegated_Tokens : Long_Long_Integer := -1;
      Compactions     : Long_Long_Integer := -1;
      Prompt_Read     : Long_Long_Integer := -1;
      Prompt_Reused   : Long_Long_Integer := -1;
   end record;

   --  @param Name One task name, without separators.
   --  @return Whether the trial registry defines this task.
   function Known_Task (Name : String) return Boolean;

   --  Qualify the pilot's coding verifiers without a model.
   --  @param Directory Scratch directory for fresh grader fixtures.
   --  @param Clean Whether reference, no-op, wrong-answer and scope controls pass.
   procedure Validate_Graders (Directory : String; Clean : out Boolean);

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
   --    agents.max_seconds in the project, and the wait for it past that;
   --    0, unless said, for the model's pace (agents.max_seconds=model).
   --  @param Context_Size The session's context, in tokens (--context-size);
   --    0, unless said, for the session's own, as a person's session has
   --    it. Kept with each run in the history (context: N, or own); runs
   --    from before it was kept ran at 8192. What a reply and its thought
   --    may take grow with it.
   --  @param Accept_Lessons Whether a carried run first accepts, as a person
   --    would, the decisions the harness proposed from what earlier runs
   --    mended alike (--accept on): what the checks hold work to, then in
   --    every task's context as a decision rather than an observation.
   --  @param Whole_Files Whether the project retrieves its context as it
   --    did before excerpts (--retrieval whole): the large task's measure.
   --  @param Inference How its calls are set (--inference): fixed, as the
   --    session is; adaptive, by the kinds' profiles and what each call is
   --    for; reasoning or temperature, adaptive with only that half of each
   --    profile taken; thinking-off, as fixed but with thinking off
   --    for every call; helpers-off, as adaptive but with thinking off for
   --    a helper that writes only documents; or a profile's name, every call by it -- the measure
   --    of an inference policy against fixed settings.
   --  @param Output_Directory Optional parent for isolated trial projects; empty retains the usual location.
   --  @param On_Attempt Receives the independently graded result after the retained project has its final name.
   --  @param Extra_Arguments Native arguments appended without splitting, preserving paths containing spaces.
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
      Max_Seconds : Natural := 0;
      Context_Size : Natural := 0;
      Accept_Lessons : Boolean := False;
      Whole_Files    : Boolean := False;
      Inference      : String := "fixed";
      Output_Directory : String := "";
      On_Attempt : access procedure (Item : Attempt) := null;
      Extra_Arguments : Hostkit.String_Vectors.Vector := Hostkit.String_Vectors.Empty_Vector);

end Agent_Trial;
