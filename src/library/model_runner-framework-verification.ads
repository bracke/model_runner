private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Deciding, without a model, whether work is done.
--
--  A verification profile is the configuration's profile NAME: checks
--  separated by semicolons, each LABEL: COMMAND, LABEL in DIRECTORY:
--  COMMAND to run it somewhere in the project, and LABEL? for one whose
--  failure does not fail the profile. Running a profile runs each check
--  through the execution layer and reads what the tools said into
--  diagnostics -- tool, severity, file, line, column, message -- and the
--  run is kept as evidence: what ran, against which state of the
--  repository, the configuration and the requirements, and what came of it.
--  Evidence is never changed afterwards.
--
--  Evidence is current only while what it was gathered against is: the
--  same files, the same configuration, the same revisions of the
--  requirements it covers. A task completes through its gates -- current
--  passing evidence for its profile, its children done, nothing blocking --
--  and never because an agent says it is done. A requirement becomes
--  verified when the tasks serving it are complete and their evidence is
--  current, and goes back to implemented, recorded, when that evidence
--  stops being so.
package Model_Runner.Framework.Verification is

   --  One check of a profile.
   --  A check is written LABEL[OPTIONS]? in DIRECTORY: COMMAND, where ?
   --  makes it optional and OPTIONS, separated by commas, may say
   --  timeout=SECONDS, retry=TIMES, severity=warning -- a failure recorded
   --  that does not fail the profile -- and keep=summary, for evidence that
   --  keeps only the end of its output.
   type Check is record
      Label     : Ada.Strings.Unbounded.Unbounded_String;
      Command   : Ada.Strings.Unbounded.Unbounded_String;
      Directory : Ada.Strings.Unbounded.Unbounded_String;
      Required  : Boolean := True;
      Timeout   : Natural := 0;
      Retries   : Natural := 0;
      Warning   : Boolean := False;
      Keep_Whole : Boolean := True;
   end record;

   --  One thing a tool said.
   type Diagnostic is record
      Tool     : Ada.Strings.Unbounded.Unbounded_String;
      Severity : Ada.Strings.Unbounded.Unbounded_String;
      File     : Ada.Strings.Unbounded.Unbounded_String;
      Line     : Natural := 0;
      Column   : Natural := 0;
      Message  : Ada.Strings.Unbounded.Unbounded_String;

      --  The tool's own name for it, where it gives one: -gnatwu, E0308.
      Code     : Ada.Strings.Unbounded.Unbounded_String;

      --  The name it is about, where it quotes one.
      Symbol   : Ada.Strings.Unbounded.Unbounded_String;

      --  The other places it points at, as FILE:LINE, separated by ;.
      Related  : Ada.Strings.Unbounded.Unbounded_String;

      --  Where it was said: the raw log's result and its line there, as
      --  RES-...:LINE.
      Raw      : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  One gate, and whether it passed.
   type Gate is record
      Name   : Ada.Strings.Unbounded.Unbounded_String;
      Passed : Boolean := False;
      Reason : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Checks, diagnostics or gates, in order.
   type Check_List is private;
   type Diagnostic_List is private;
   type Gate_List is private;

   --  How many a list holds.
   --
   --  @param From The list.
   --  @return The count.
   function Length (From : Check_List) return Natural;

   --  @param From The list.
   --  @return The count.
   function Length (From : Diagnostic_List) return Natural;

   --  @param From The list.
   --  @return The count.
   function Length (From : Gate_List) return Natural;

   --  One of them.
   --
   --  @param From The list.
   --  @param Index 1 .. Length.
   --  @return The check.
   function Element (From : Check_List; Index : Positive) return Check;

   --  @param From The list.
   --  @param Index 1 .. Length.
   --  @return The diagnostic.
   function Element (From : Diagnostic_List; Index : Positive) return Diagnostic;

   --  @param From The list.
   --  @param Index 1 .. Length.
   --  @return The gate.
   function Element (From : Gate_List; Index : Positive) return Gate;

   --  The checks a profile holds.
   --
   --  @param Text The profile, as the configuration writes it.
   --  @return Its checks, in order.
   function Parse_Profile (Text : String) return Check_List;

   --  What tools said, from their output: lines of FILE:LINE:COLUMN:
   --  [SEVERITY:] MESSAGE, as GNAT and GCC write them, and lines starting
   --  error: or warning:. A style message is a warning. A trailing [CODE]
   --  or error[CODE] is its code, the first quoted name its symbol, and
   --  "at FILE:LINE" or "at line N" in it a related place.
   --
   --  @param Tool What wrote the output.
   --  @param Output The output.
   --  @param Raw_Log The result the whole output is kept as, for each
   --    diagnostic's reference back to where it was said.
   --  @return The diagnostics, in order.
   function Normalize
     (Tool    : String;
      Output  : String;
      Raw_Log : String := "") return Diagnostic_List;

   --  The verification profile a task is checked by: the configuration's
   --  scalar task.profile.KIND, else scalar verification.default.
   --
   --  @param Item The store.
   --  @param Task_Id The task.
   --  @return The profile's name, or the empty string for none.
   function Profile_Of (Item : Stores.Store; Task_Id : String) return String;

   --  Run a profile for a task, and keep the evidence.
   --
   --  @param Item The store.
   --  @param Change The transaction the evidence is staged in.
   --  @param Profile The profile.
   --  @param Task_Id The task; may be empty for a run for the project.
   --  @param Evidence The evidence's identifier, VER- and a number.
   --  @param Passed Whether every required check passed.
   --  @param Status Framework_Not_Found when there is no such profile,
   --    Framework_Execution_Refused when the policy refuses one of its
   --    commands.
   --  @param Given Values its commands and directories may use, as
   --    NAME=VALUE: {NAME} in a check stands for VALUE. Each is kept on the
   --    evidence.
   --  @param Stands_For The task's own profile, when this narrower one is
   --    run in its place; its evidence then counts for that profile.
   --  @param Offline Whether it runs for an agent without use_network, its
   --    commands kept off the network where the host can do that.
   --  @param Workspace A workspace's tree to run it in rather than the
   --    project: the work before it is taken in. Its evidence says so and
   --    names the tree's own revision, and never counts as the project's.
   procedure Run_Profile
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Profile  : String;
      Task_Id  : String;
      Evidence : out Ada.Strings.Unbounded.Unbounded_String;
      Passed   : out Boolean;
      Status   : out Model_Runner.Errors.Error_Info;
      Given    : Name_Lists.Vector := Name_Lists.Empty_Vector;
      Stands_For : String := "";
      Offline  : Boolean := False;
      Workspace : String := "");

   --  How widely a task's work is verified, and with what.
   type Choice is record
      --  The profile to run, and the task's own it answers for when that is
      --  another.
      Profile    : Ada.Strings.Unbounded.Unbounded_String;
      Stands_For : Ada.Strings.Unbounded.Unbounded_String;

      --  How widely: certain_tests, component_tests or full_suite, and why.
      Scope      : Ada.Strings.Unbounded.Unbounded_String;
      Reason     : Ada.Strings.Unbounded.Unbounded_String;

      --  What the checks may use: tests, scope, component, as NAME=VALUE.
      Given      : Name_Lists.Vector;
   end record;

   --  Choose how to verify a task's work from what it changed: what the
   --  change reaches in the traceability graph, the tests that selects and
   --  how sure it is, and the project's policy. A narrower scope runs the
   --  profile the configuration names for it -- scalar
   --  verification.scope.KIND.WIDTH, else verification.scope.WIDTH, with
   --  WIDTH certain or component -- and otherwise, as for the full suite,
   --  the task's own profile. What cannot be traced is verified in full.
   --
   --  @param Item The store.
   --  @param Task_Id The task.
   --  @param Changed The files its work changed.
   --  @return The choice; an empty profile when none applies.
   function Choose
     (Item    : Stores.Store;
      Task_Id : String;
      Changed : Name_Lists.Vector) return Choice;

   --  The diagnostics a piece of evidence recorded.
   --
   --  @param Item The store.
   --  @param Evidence The evidence.
   --  @return Its diagnostics.
   function Diagnostics_Of
     (Item     : Stores.Store;
      Evidence : String) return Diagnostic_List;

   --  Whether evidence still applies: the same files, configuration and
   --  requirement revisions as when it was gathered.
   --
   --  @param Item The store.
   --  @param Evidence The evidence.
   --  @param Reasons Why not, when it does not.
   --  @param Configuration The configuration fingerprint to hold it to:
   --    empty for the one in force, or one being staged.
   --  @return True when it applies.
   function Is_Current
     (Item          : Stores.Store;
      Evidence      : String;
      Reasons       : out Name_Lists.Vector;
      Configuration : String := "") return Boolean;

   --  The latest evidence for a task and profile.
   --
   --  @param Item The store.
   --  @param Task_Id The task.
   --  @param Profile The profile.
   --  @return Its identifier, or the empty string when there is none.
   function Latest
     (Item    : Stores.Store;
      Task_Id : String;
      Profile : String) return String;

   --  A task's completion gates: the configuration's set task.gates, by
   --  default verification, children, no_blocking_issue and integration --
   --  no workspace of its work left untaken.
   --
   --  @param Item The store.
   --  @param Task_Id The task.
   --  @return Each gate and whether it passes.
   function Gates (Item : Stores.Store; Task_Id : String) return Gate_List;

   --  Complete a task through its gates, and mark the requirements it
   --  serves implemented.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Task_Id The task.
   --  @param Status Framework_Task_Not_Ready naming the gates that did not
   --    pass.
   procedure Complete_Task
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Task_Id : String;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Verify a requirement itself by the project's profile for
   --  requirements, scalar verification.requirements: {requirement} in a
   --  check stands for its identifier and {tests} for the tests it names.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Requirement The requirement.
   --  @param Evidence The evidence taken.
   --  @param Passed Whether it passed.
   --  @param Status Framework_Not_Found when the project names no such
   --    profile or there is no such requirement.
   procedure Verify_Requirement
     (Item        : Stores.Store;
      Change      : in out Stores.Transaction;
      Requirement : String;
      Evidence    : out Ada.Strings.Unbounded.Unbounded_String;
      Passed      : out Boolean;
      Status      : out Model_Runner.Errors.Error_Info);

   --  Work out again which requirements are verified: an implemented one
   --  whose serving tasks are complete with current passing evidence,
   --  that something implements -- a linked implementation, or files a
   --  serving task changed -- and, where the project names a profile for
   --  requirements (scalar verification.requirements), that has current
   --  passing evidence of it taken for the requirement itself, becomes
   --  verified, naming that evidence; a verified one whose evidence
   --  stopped applying goes back to implemented.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Changed The requirements whose state changed.
   --  @param Status A failure staging a change.
   --  @param Configuration The configuration fingerprint evidence is held
   --    to: empty for the one in force, or that of a change staged in the
   --    same transaction, so that both are committed as one.
   procedure Reevaluate_Requirements
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Changed : out Name_Lists.Vector;
      Status  : out Model_Runner.Errors.Error_Info;
      Configuration : String := "");

private

   package Check_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Check);

   package Diagnostic_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Diagnostic);

   package Gate_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Gate);

   type Check_List is record
      Items : Check_Vectors.Vector;
   end record;

   type Diagnostic_List is record
      Items : Diagnostic_Vectors.Vector;
   end record;

   type Gate_List is record
      Items : Gate_Vectors.Vector;
   end record;

end Model_Runner.Framework.Verification;
