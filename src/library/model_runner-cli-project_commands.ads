with Ada.Strings.Unbounded;

with Model_Runner.Cancellation;
with Model_Runner.CLI.Options;
with Model_Runner.Errors;
with Model_Runner.Framework.Context;
with Model_Runner.Framework.Work;
with Model_Runner.Llama;
with Model_Runner.Presentation;
with Model_Runner.Stops;

--  The project's commands, typed in the conversation.
--
--  A session with a model is where a project is developed, so the harness's
--  commands are typed there, between turns, as slash commands:
--
--    /init [TEMPLATE] [NAME=VALUE ...]     start the project's state
--    /bootstrap [FILE ...]                 read documents for requirements
--    /state                                where the project stands
--    /config                               the resolved configuration
--    /task [ACTION] [ARGUMENT] [NAME=VALUE ...]
--                                          list and manage tasks
--    /accept   /reject                     the one candidate waiting
--    /work [TASK]                          run a ready task, on this model
--    /cancel [TASK]                        cancel a task
--    /check [full]                         verify the project now
--    /req [ID]   /result ID                read a requirement or a result
--    /tree   /sym NAME   /refs NAME   /impact FILE   /trace NODE
--                                          ask the repository
--
--  The project is the directory the session was started in. None of these
--  asks the model anything except /work, and /work asks it in a
--  conversation of its own: its context is built from the project state,
--  never from the conversation on the screen, and the conversation on the
--  screen is left as it was. The model works with the built-in file tools
--  only -- no shell, no network -- inside the project or the workspace the
--  task is given, and may hand a part of the work to a child agent the
--  harness makes and answers for.
package Model_Runner.CLI.Project_Commands is

   --  An agent that is the session's own model, already loaded. Cancel, when
   --  it is set, stops it and every child it made at the next token.
   type Session_Agent
     (Prepared : not null access Model_Runner.Llama.Model;
      Session  : not null access Model_Runner.Llama.Session;
      Stop_Set : not null access constant Model_Runner.Stops.Set;
      Screen   : not null access Model_Runner.Presentation.Console;
      Item     : not null access constant Model_Runner.CLI.Options.Command;
      Cancel   : Model_Runner.Cancellation.Token_Reference)
   is new Model_Runner.Framework.Work.Parenting_Runner with null record;

   --  Run the agent without children: a fresh conversation holding the
   --  task's context, the agent loop with the file tools, and the session
   --  left reset so the conversation on the screen is read again on its next
   --  turn.
   --
   --  @param Self The agent.
   --  @param Prompt_Path Where the task's context is.
   --  @param Project Where it works.
   --  @param Answer Its final answer.
   --  @param Status A failure of the loop.
   overriding procedure Run
     (Self        : Session_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info);

   --  Run the agent with children: as Run, and where its permissions let
   --  it, it may hand a part of the work to a helper with the delegate tool.
   --  The harness makes the child through Children; it runs on the same
   --  session in a conversation of its own, with the tools its own
   --  permissions give, and its parent is told only its result.
   --
   --  @param Self The agent.
   --  @param Prompt_Path Where the task's context is.
   --  @param Project Where it works.
   --  @param Children Where its children are made.
   --  @param Answer Its final answer.
   --  @param Status A failure of the loop.
   overriding procedure Run_Parenting
     (Self        : Session_Agent;
      Prompt_Path : String;
      Project     : String;
      Children    : in out Model_Runner.Framework.Work.Child_Host'Class;
      Answer      : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info);

   --  Look at the state of the project in the session's directory, if there
   --  is one, as the session starts: what an interruption left is put right
   --  and said, before anything is asked of it.
   --
   --  @param Screen Where to write.
   procedure Recover_Here (Screen : in out Model_Runner.Presentation.Console);

   --  The session's model, as /work budgets a context for it: its file name,
   --  the session's own context size, the reply length asked for, and the
   --  tools it is offered.
   --
   --  @param Self The agent.
   --  @return Its profile.
   overriding function Profile
     (Self : Session_Agent) return Model_Runner.Framework.Context.Model_Profile;

   --  Whether a word is one of the project's commands.
   --
   --  @param Word The word as typed, slash included.
   --  @return True when it is.
   function Is_Project_Command (Word : String) return Boolean;

   --  One help line for each command.
   --
   --  @param Screen Where to write.
   procedure Help (Screen : in out Model_Runner.Presentation.Console);

   --  Carry out a project command.
   --
   --  @param Line The line as typed.
   --  @param Screen Where to write.
   --  @param Agent The agent /work runs.
   procedure Run
     (Line   : String;
      Screen : in out Model_Runner.Presentation.Console;
      Agent  : Model_Runner.Framework.Work.Agent_Runner'Class);

end Model_Runner.CLI.Project_Commands;
