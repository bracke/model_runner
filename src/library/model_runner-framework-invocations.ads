private with Ada.Containers.Indefinite_Ordered_Maps;

with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Each call made to a model, kept as history, and what it may answer.
--
--  An invocation is its own record, apart from the agent that made it and
--  the task it was for: which agent, which task and execution generation,
--  which model profile, which context manifest, which tools it was allowed,
--  which result contract it was to answer by, when it started and how it
--  ended, what it used, and what it produced or why it failed. A retry is a
--  new invocation; an invocation that has ended is not changed again.
--
--  A model does not change project state. It answers, and the answer is
--  held to a contract: named fields, some required, some limited to a set
--  of words. An answer that keeps to it becomes claims the harness then
--  checks and acts on; one that does not is refused, by name.
package Model_Runner.Framework.Invocations is

   --  How an invocation ended.
   type Ending is (Completed, Failed, Cancelled);

   --  What an invocation used.
   type Usage is record
      Prompt_Tokens : Natural := 0;
      Output_Tokens : Natural := 0;
      Seconds       : Natural := 0;
   end record;

   --  What a model's answer must hold: one field a line, as
   --  NAME or NAME? for an optional one, and NAME = WORD|WORD for one that
   --  must be one of those words.
   type Contract is private;

   --  What an answer that kept to its contract says.
   type Claims is private;

   --  Read a contract.
   --
   --  @param Name What the contract is called, as work_claim.
   --  @param Text Its fields, one a line.
   --  @return The contract.
   function Contract_Of (Name : String; Text : String) return Contract;

   --  The contract a work agent answers by: status done, blocked, failed
   --  or issue; a summary; and optionally the files it changed, the issues
   --  it found and the tasks it proposes.
   --
   --  @return The contract.
   function Work_Claim return Contract;

   --  A contract's name.
   --
   --  @param Item The contract.
   --  @return Its name.
   function Name_Of (Item : Contract) return String;

   --  Hold an answer to a contract. The answer is lines of NAME: VALUE;
   --  a value runs on over the lines after it that do not start a field,
   --  and anything before the first field is passed over.
   --
   --  @param Rules The contract.
   --  @param Answer The model's answer.
   --  @param Result The claims, when Status is a success.
   --  @param Status Framework_Contract_Violation naming the field that is
   --    missing, or holds a word it may not.
   procedure Hold
     (Rules  : Contract;
      Answer : String;
      Result : out Claims;
      Status : out Model_Runner.Errors.Error_Info);

   --  One claim.
   --
   --  @param From The claims.
   --  @param Name The field.
   --  @return Its value, or the empty string when the answer gave none.
   function Claim (From : Claims; Name : String) return String;

   --  Record that a call is starting.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Agent The agent making it.
   --  @param Task_Id The task it is for; may be empty.
   --  @param Generation The task's execution generation.
   --  @param Profile The model profile.
   --  @param Manifest The context manifest.
   --  @param Tool_Policy The tools it may use, as words.
   --  @param Rules The result contract.
   --  @param Id The invocation's identifier, INV- and a number.
   --  @param Status A failure allocating it; Framework_Limit_Exceeded when
   --    the task's execution generation has made as many calls as scalar
   --    agents.max_invocations allows, its root's and every child's
   --    together.
   --  @param Resource_Class The model's memory or resource class, where
   --    it is known.
   procedure Start
     (Item        : Stores.Store;
      Change      : in out Stores.Transaction;
      Agent       : String;
      Task_Id     : String;
      Generation  : String;
      Profile     : String;
      Manifest    : String;
      Tool_Policy : String;
      Rules       : Contract;
      Id          : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info;
      Resource_Class : String := "");

   --  Record how a call ended.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The invocation.
   --  @param How How it ended.
   --  @param Used What it used.
   --  @param Result_Id The result it produced; may be empty.
   --  @param Failure Why it failed; may be empty.
   --  @param Status Framework_Transition_Invalid when it has ended already.
   procedure Finish
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Id        : String;
      How       : Ending;
      Used      : Usage;
      Result_Id : String;
      Failure   : String;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Record a tool call an invocation made: its name, and the start of its
   --  arguments and of what it answered, so a call can be traced to the
   --  agent and invocation that made it.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The invocation, started and not ended.
   --  @param Named The tool.
   --  @param Arguments Its arguments.
   --  @param Answer What it answered.
   --  @param Status Framework_Not_Found when there is no such invocation.
   --  @param Number The entry Note_Start made for it, to fill in; nought
   --    for a new entry.
   --  @param Ended How it ended, as a word -- answered, failed, or
   --    refused and by what -- kept after the answer; "" for none.
   procedure Note_Call
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Id        : String;
      Named     : String;
      Arguments : String;
      Answer    : String;
      Status    : out Model_Runner.Errors.Error_Info;
      Number    : Natural := 0;
      Ended     : String := "");

   --  The calls an invocation recorded as refused, as their entries name
   --  them: the tool, the start of its arguments, and what refused it.
   --
   --  @param Item The store.
   --  @param Id The invocation.
   --  @return Them, in the order made; empty for none.
   function Refused_Calls (Item : Stores.Store; Id : String) return Name_Lists.Vector;

   --  The last invocation made for a task, or "".
   --
   --  @param Item The store.
   --  @param Task_Id The task.
   --  @return Its identifier.
   function Last_For (Item : Stores.Store; Task_Id : String) return String;

   --  What a call's entry says in place of its answer while it runs.
   Unanswered : constant String := "(started; not answered)";

   --  Record a call that may change state as started, before it runs: an
   --  entry as Note_Call writes, its answer Unanswered, for Note_Call to
   --  fill in by Number once it has answered. A run that stops between
   --  leaves the entry saying so, and recovery names it.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The invocation, started and not ended.
   --  @param Named The tool.
   --  @param Arguments Its arguments.
   --  @param Number The entry's number, for Note_Call.
   --  @param Status Framework_Not_Found when there is no such invocation.
   procedure Note_Start
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Id        : String;
      Named     : String;
      Arguments : String;
      Number    : out Natural;
      Status    : out Model_Runner.Errors.Error_Info);

   --  The calls an invocation started and never answered, as their entries
   --  name them: the tool and the start of its arguments.
   --
   --  @param Item The store.
   --  @param Id The invocation.
   --  @return Them; empty for none.
   function Unanswered_Calls (Item : Stores.Store; Id : String) return Name_Lists.Vector;

   --  Where an invocation stands: started, completed, failed or cancelled.
   --
   --  @param Item The store.
   --  @param Id The invocation.
   --  @return Its state, or the empty string when there is none.
   function State_Of (Item : Stores.Store; Id : String) return String;

private

   package Field_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => String);

   type Contract is record
      Name     : Ada.Strings.Unbounded.Unbounded_String;

      --  Each field and what it takes: "" for anything, "?" for anything
      --  or nothing, or the words it may be separated by |.
      Fields   : Field_Maps.Map;
      Optional : Name_Lists.Vector;
      Order    : Name_Lists.Vector;
   end record;

   type Claims is record
      Values : Field_Maps.Map;
   end record;

end Model_Runner.Framework.Invocations;
