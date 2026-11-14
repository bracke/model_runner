with Model_Runner.Tools.Runner;
with Model_Runner.Tools.Builtin;
with Model_Runner.Errors;
with Ada.Strings.Unbounded;
with Model_Runner.Agent;
with Model_Runner.Presentation;

--  A conversation's turns with the tools: what is asked before a call runs,
--  and what /undo puts back.
--
--  A call that only reads -- the files, the clock, a sum, the project's
--  graph -- runs unasked; one that changes something, starts a program or
--  reaches the network is asked in the selector first: this once, the tool
--  for the rest of the session, not this one (the model is told and may try
--  another way), or stop the turn. Esc is no; with no terminal to ask at,
--  it is not run.
--
--  Before a call that writes or edits a file runs, the file as it was is
--  kept -- its bytes, or that it was not there -- with the turn it was
--  changed in; /undo puts back the files the last turn changed, and again
--  the turn's before it. What a program a shell ran changed is not kept.
package Model_Runner.CLI.Tool_Turns is

   type Conversation_Approver (Screen : access Model_Runner.Presentation.Console) is
     limited new Model_Runner.Agent.Approver with private;

   overriding function Consider
     (Self : in out Conversation_Approver; Named : String; Arguments : String)
      return Model_Runner.Agent.Verdict;

   --  Plan mode: while it is on, a call that would change something is not
   --  run and nobody is asked -- the model reads, and proposes.
   --
   --  @param On Whether plan mode is on.
   procedure Set_Planning (On : Boolean);

   --  Whether plan mode is on.
   function Planning return Boolean;

   --  Let a tool run unasked for the rest of the session, as "yes, and
   --  this tool" does.
   --
   --  @param Self The approver.
   --  @param Named The tool's name.
   procedure Allow_Always (Self : in out Conversation_Approver; Named : String);

   --  The folder a call's relative path is in, as the tools' own base is:
   --  where the session is, unless set.
   --
   --  @param Directory The folder.
   procedure Set_Base (Directory : String);

   --  A turn with the tools begins: what it changes is kept apart from the
   --  turn's before it.
   procedure Begin_Turn;

   --  The file a call names, as its "path" argument says it; "" where it
   --  names none.
   --
   --  @param Arguments The call's arguments, as JSON.
   --  @return The path.
   function Path_Of (Arguments : String) return String;

   --  Keep a file as it is, before a call changes it -- once a turn.
   --
   --  @param Path The file.
   procedure Before_Change (Path : String);

   --  Put back the files the latest turn that changed any changed: each as
   --  it was, or gone where it was not there.
   --
   --  @param Restored The files put back, a line each; "" where no turn
   --    changed any.
   procedure Undo (Restored : out Ada.Strings.Unbounded.Unbounded_String);

   --  The built-in tools with the user's hooks: after a write or an edit
   --  that ran, the settings file's hook.after-edit runs -- $FILE in it
   --  the file's quoted path -- and what it said, with how it ended, is
   --  put after the tool's answer, so the model reads it too.
   type Hooked_Instance is new Model_Runner.Tools.Builtin.Instance with null record;

   overriding procedure Run
     (Self      : in out Hooked_Instance;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Outcome   : out Model_Runner.Tools.Runner.Call_Outcome;
      Status    : out Model_Runner.Errors.Error_Info);

   --  A hook the settings file names, run by the host's shell in the
   --  session's folder: "" where none is set, else what it said and how it
   --  ended.
   --
   --  @param Key The setting: hook.after-edit, hook.after-turn.
   --  @param File The file to put for $FILE, or "".
   --  @param Failed Whether it ended other than with status 0.
   --  @return What it said, its status after.
   function Run_Hook (Key, File : String; Failed : out Boolean) return String;

private

   type Conversation_Approver (Screen : access Model_Runner.Presentation.Console) is
     limited new Model_Runner.Agent.Approver with record
        --  The tools allowed for the session, a space either side of each.
        Always : Ada.Strings.Unbounded.Unbounded_String :=
          Ada.Strings.Unbounded.To_Unbounded_String (" ");
     end record;

end Model_Runner.CLI.Tool_Turns;
