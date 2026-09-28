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
   type Check is record
      Label     : Ada.Strings.Unbounded.Unbounded_String;
      Command   : Ada.Strings.Unbounded.Unbounded_String;
      Directory : Ada.Strings.Unbounded.Unbounded_String;
      Required  : Boolean := True;
   end record;

   --  One thing a tool said.
   type Diagnostic is record
      Tool     : Ada.Strings.Unbounded.Unbounded_String;
      Severity : Ada.Strings.Unbounded.Unbounded_String;
      File     : Ada.Strings.Unbounded.Unbounded_String;
      Line     : Natural := 0;
      Column   : Natural := 0;
      Message  : Ada.Strings.Unbounded.Unbounded_String;
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
   --  error: or warning:. A style message is a warning.
   --
   --  @param Tool What wrote the output.
   --  @param Output The output.
   --  @return The diagnostics, in order.
   function Normalize (Tool : String; Output : String) return Diagnostic_List;

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
   procedure Run_Profile
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Profile  : String;
      Task_Id  : String;
      Evidence : out Ada.Strings.Unbounded.Unbounded_String;
      Passed   : out Boolean;
      Status   : out Model_Runner.Errors.Error_Info);

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
   --  @return True when it applies.
   function Is_Current
     (Item     : Stores.Store;
      Evidence : String;
      Reasons  : out Name_Lists.Vector) return Boolean;

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
   --  default verification, children and no_blocking_issue.
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

   --  Work out again which requirements are verified: an implemented one
   --  whose serving tasks are complete with current passing evidence
   --  becomes verified, naming that evidence; a verified one whose
   --  evidence stopped applying goes back to implemented.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Changed The requirements whose state changed.
   --  @param Status A failure staging a change.
   procedure Reevaluate_Requirements
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Changed : out Name_Lists.Vector;
      Status  : out Model_Runner.Errors.Error_Info);

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
