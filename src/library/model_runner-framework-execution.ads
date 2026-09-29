with Ada.Strings.Unbounded;

with Model_Runner.Cancellation;
with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Every external program the harness runs, run one way.
--
--  A command runs only when the project's policy allows its program --
--  the configuration's set execution.allowed names them -- and only
--  directly: a command that needs a shell (&&, a pipe, a redirection) is
--  refused unless the policy says scalar execution.shell = allowed. It runs
--  in a directory inside the project, with nothing on its standard input,
--  with PATH, HOME and the variables set execution.environment names and
--  no others, under a deadline, and with its output kept -- whole as a raw
--  log among the results, and cut to a limit where it is read. Having the
--  right to run a build is not having a shell: an agent is given the
--  checks the configuration defines, not this.
package Model_Runner.Framework.Execution is

   --  What may be run, and how.
   type Policy is record
      --  The programs that may run, by name.
      Allowed       : Name_Lists.Vector;
      Shell_Allowed : Boolean := False;

      --  Variables passed beyond PATH and HOME, separated by commas.
      Environment   : Ada.Strings.Unbounded.Unbounded_String;

      Timeout       : Positive := 600;
      Output_Limit  : Positive := 1024 * 1024;

      --  Whether the whole output is kept as the raw log, or only its last
      --  part, where a check says its evidence need not keep it all.
      Keep_Whole    : Boolean := True;

      --  Whether a check may use the network, as recorded with what ran;
      --  and whether the policy denies it outright (scalar
      --  execution.network = denied), which, where the host can take the
      --  network away from one program, it is.
      Network       : Boolean := False;
      No_Network    : Boolean := False;

      --  Limits on each command, zero for none: its memory, processor
      --  time, processes and the size of a file it writes. Where a limit is
      --  asked for and cannot be set, the command is refused rather than
      --  run without it.
      Memory_MB     : Natural := 0;
      CPU_Seconds   : Natural := 0;
      Processes     : Natural := 0;
      File_MB       : Natural := 0;

      --  How many commands may run at once across every harness working
      --  on the project; zero for no bound.
      Process_Slots : Natural := 0;
   end record;

   --  What became of a command.
   type Outcome is record
      Command     : Ada.Strings.Unbounded.Unbounded_String;
      Directory   : Ada.Strings.Unbounded.Unbounded_String;
      Started     : Boolean := False;
      Timed_Out   : Boolean := False;
      Exit_Status : Integer := -1;
      Seconds     : Natural := 0;

      --  Standard output and standard error together, cut to the limit.
      Output      : Ada.Strings.Unbounded.Unbounded_String;

      --  The result the whole output is kept as.
      Raw_Log     : Ada.Strings.Unbounded.Unbounded_String;

      --  Whether it was stopped because the run was cancelled.
      Cancelled   : Boolean := False;

      --  Whether the network was taken away from it.
      Isolated    : Boolean := False;
   end record;

   --  The token whose cancellation stops a running command: set by whoever
   --  runs the harness -- a session routes Ctrl-C to it -- and asked while
   --  every command waits, which is then stopped as a deadline stops it.
   --
   --  @param Token The token; null for none.
   procedure Watch (Token : Model_Runner.Cancellation.Token_Reference);

   --  The work whose ending elsewhere stops what runs for it: while it is
   --  watched, a command or harness program running is stopped -- as a
   --  cancellation stops it -- once the lease no longer names its owner;
   --  another process cancelled the task, say. Asked at most once a second.
   --
   --  @param Item The store the lease is in; null to watch nothing.
   --  @param Resource The lease.
   --  @param Owner The agent that holds it.
   procedure Watch_Lease
     (Item     : access constant Stores.Store;
      Resource : String := "";
      Owner    : String := "");

   --  Whether the work watched has been ended elsewhere: its lease no
   --  longer names its owner.
   --
   --  @return True when it has.
   function Work_Withdrawn return Boolean;

   --  Ask the run working on a task in a project -- another process, which
   --  holds the project -- to stop it: what it runs is stopped as a
   --  cancellation stops it, and the task is set aside.
   --
   --  @param Project_Directory The project.
   --  @param Task_Id The task.
   procedure Ask_To_Stop (Project_Directory : String; Task_Id : String);

   --  Whether whoever runs the harness has asked it to stop -- Ctrl-C --
   --  through the token Watch was given: asked by a runner whose program
   --  ended before the harness stopped it, the interrupt having reached it
   --  first.
   --
   --  @return True when the watched token is cancelled.
   function Cancel_Requested return Boolean;

   --  The project's policy, from its configuration.
   --
   --  @param Item The store.
   --  @return The policy.
   function Policy_Of (Item : Stores.Store) return Policy;

   --  Whether a command needs a shell to run as written.
   --
   --  @param Command The command.
   --  @return True when it holds a shell's operators.
   function Needs_Shell (Command : String) return Boolean;

   --  A command's words, as a shell would split plain ones: at blanks,
   --  with quoted stretches kept whole.
   --
   --  @param Command The command.
   --  @return Its words.
   function Words_Of (Command : String) return Name_Lists.Vector;

   --  Why the policy would not run a command, before anything is run: it
   --  is empty, it needs a shell the policy does not allow, its program is
   --  not one the policy allows -- listed by its name or by its path -- or
   --  a limit it asks for cannot be set.
   --
   --  @param Rules The policy.
   --  @param Command What would be run.
   --  @return Why not, or the empty string when it would be run.
   function Refusal (Rules : Policy; Command : String) return String;

   --  Run a command.
   --
   --  @param Item The store, whose project the command runs in.
   --  @param Change The transaction the raw log is staged in.
   --  @param Rules The policy.
   --  @param Command What to run.
   --  @param Directory Where, inside the project; empty for its top.
   --  @param Result What became of it.
   --  @param Base The tree the directory is in: empty for the project, or
   --    a workspace's tree, which must be one of the project's.
   --  @param Status Framework_Execution_Refused when the policy does not
   --    allow it or a limit it asks for cannot be set,
   --    Framework_Limit_Exceeded when every process slot is taken; a
   --    success whatever the command itself returned.
   procedure Run
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Rules     : Policy;
      Command   : String;
      Directory : String;
      Result    : out Outcome;
      Status    : out Model_Runner.Errors.Error_Info;
      Base      : String := "");

   --  One of the harness's own programs -- git, or this program started as
   --  an agent -- run the same way as a project's command: nothing on its
   --  standard input, only PATH, HOME, the variables named and the
   --  assignments given, under a deadline, and a line in the project's
   --  harness log saying what ran, where, for how long and how it ended.
   --  It is not the project's policy that allows it: the harness needs it,
   --  and a project that listed git or model_runner would be letting its
   --  checks run them too.
   --
   --  @param Project The project, whose state keeps the log; "" when the
   --    directory is not one yet.
   --  @param Program The program, found on PATH or given whole.
   --  @param Arguments Its arguments.
   --  @param Directory Where it runs.
   --  @param Output The file its standard output is written to.
   --  @param Timeout Seconds it may take.
   --  @param Result What became of it; Output there is the end of what it
   --    said on its error stream, which the harness log keeps too.
   --  @param Passed More variables to pass, separated by commas.
   --  @param Added NAME=VALUE assignments to give it.
   procedure Run_Harness
     (Project   : String;
      Program   : String;
      Arguments : Name_Lists.Vector;
      Directory : String;
      Output    : String;
      Timeout   : Positive;
      Result    : out Outcome;
      Passed    : String := "";
      Added     : Name_Lists.Vector := Name_Lists.Empty_Vector);

   --  The harness log's file in a project's state.
   --
   --  @param Project The project.
   --  @return Its path.
   function Harness_Log (Project : String) return String;

end Model_Runner.Framework.Execution;
