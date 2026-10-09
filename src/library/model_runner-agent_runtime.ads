with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

with Model_Runner.Tools.Registry;

--  What every way of running an agent shares, so that run's agent and
--  /work's agents are one runtime configured two ways rather than two
--  runtimes that drift: what a helper is handed and told, and how what it
--  was to write is checked.
--
--  The tools an agent is offered come from Tools.Registry by its
--  capabilities, for either. A helper -- delegate's child -- is asked with
--  the same contract wherever it is made: the task; its role and how much
--  it is needed; the files it starts from, the files it must write, and
--  when it is done. The contract is put to it in one brief, it is told how
--  to work and report in one set of rules, and the files it was to write
--  are checked by the harness after, not taken from its word. How deep
--  helpers may go is the environment's to say -- the project's permissions
--  for /work, run's --delegate-depth -- and not whether one way of running
--  happened to make a delegator.
--
--  Task safety: no state.
package Model_Runner.Agent_Runtime is

   package Paths is new Ada.Containers.Indefinite_Vectors (Positive, String);

   --  A helper's contract, as delegate's arguments give it.
   type Contract is record
      Task_Text  : Ada.Strings.Unbounded.Unbounded_String;
      Role       : Ada.Strings.Unbounded.Unbounded_String;
      Need       : Ada.Strings.Unbounded.Unbounded_String;
      Inputs     : Ada.Strings.Unbounded.Unbounded_String;
      Outputs    : Ada.Strings.Unbounded.Unbounded_String;
      Acceptance : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  A contract from a delegate call's arguments.
   --
   --  @param Arguments The call's arguments, a JSON object.
   --  @param Found Whether it names a task.
   --  @return The contract.
   function Contract_Of (Arguments : String; Found : out Boolean) return Contract;

   --  What a helper is asked: the task, and the contract beside it, each
   --  said as what it is.
   --
   --  @param Item The contract.
   --  @return The brief.
   function Brief (Item : Contract) return String;

   --  The files a contract says the helper must write, one a word, commas or
   --  spaces apart -- the words that name a file, with a folder or an
   --  extension; outputs described in words name none.
   --
   --  @param Item The contract.
   --  @return The paths.
   function Output_Paths (Item : Contract) return Paths.Vector;

   --  What each of some files holds, as a revision -- "-" for one not there
   --  or not text -- to hold against later.
   --
   --  @param Of_Files The files.
   --  @return Their prints, in the same order.
   function Prints (Of_Files : Paths.Vector) return Paths.Vector;

   --  Of files and what they held, those that hold the same now: the outputs
   --  a helper was to write and did not.
   --
   --  @param Of_Files The files.
   --  @param Before Their prints before.
   --  @return Them, comma-separated; "" when every one was written.
   function Unwritten (Of_Files : Paths.Vector; Before : Paths.Vector) return String;

   --  How a helper works and reports, wherever it was made: do what it is
   --  asked and nothing more, change files only with the tools that change
   --  them, and end with the report lines its parent reads.
   --
   --  @return The rules, as a section of the helper's instructions.
   function Helper_Rules return String;

   --  What a helper is told of itself before its task, where no project
   --  says more: that it helps with one part, cannot see its parent's
   --  conversation, and is read only by its report.
   --
   --  @param Role What it is for, or "".
   --  @return The opening.
   function Helper_Opening (Role : String) return String;

   --  The capabilities a run's agent has, as the runner it was given is
   --  wired: everything a built-in runner carries, delegation where it may
   --  still make a helper, and somebody to ask where there is one.
   --
   --  @param May_Delegate Whether a helper may be made at this depth.
   --  @param May_Ask Whether there is somebody to ask.
   --  @return The capabilities.
   function Run_Capabilities
     (May_Delegate : Boolean; May_Ask : Boolean) return Tools.Registry.Capabilities;

end Model_Runner.Agent_Runtime;
