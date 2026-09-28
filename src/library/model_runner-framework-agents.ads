with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Stores;

--  Agents that make agents, kept inside what they were given.
--
--  Every agent has one owner: a parent agent, or the harness itself for a
--  root. A child is made by the harness when its parent asks and the
--  parent may -- it holds create_children, and neither it nor the project
--  is at its limit of depth, children or agents running -- and it is given
--  at most what its parent has: its permissions are the parent's
--  intersected with what was asked for and with its role's, so asking for
--  more gets nothing more. It gets a budget out of its parent's, and a
--  context built for it alone; a parent's conversation is never its.
--
--  A child answers with a result, which its parent reads as a reference and
--  a summary, not a transcript. A parent knows of each child whether it is
--  required, optional or advisory: it cannot complete while a required one
--  is still going, and a required child that fails is recorded on the
--  parent, where it cannot be missed. An optional or advisory one that
--  fails does not fail its parent. Cancelling an agent cancels its
--  children that are still going, and not its task.
package Model_Runner.Framework.Agents is

   --  What a parent needs of a child.
   type Obligation is (Required, Optional, Advisory);

   --  The limits the project sets, from its configuration's scalar
   --  agents.max_depth, agents.max_children, agents.max_active and
   --  agents.token_budget.
   type Limits is record
      Max_Depth    : Natural := 2;
      Max_Children : Natural := 3;
      Max_Active   : Natural := 4;
      Token_Budget : Natural := 200_000;
   end record;

   --  One agent, as recorded.
   type Agent is record
      Id          : Ada.Strings.Unbounded.Unbounded_String;
      Role        : Ada.Strings.Unbounded.Unbounded_String;
      Parent      : Ada.Strings.Unbounded.Unbounded_String;
      Task_Id     : Ada.Strings.Unbounded.Unbounded_String;
      Depth       : Natural := 0;
      Need        : Obligation := Required;
      Status      : Ada.Strings.Unbounded.Unbounded_String;
      Budget      : Natural := 0;
      Used        : Natural := 0;
      Allowed     : Permissions.Permission_Set := Permissions.Nothing;
      Result      : Ada.Strings.Unbounded.Unbounded_String;
      Summary     : Ada.Strings.Unbounded.Unbounded_String;

      --  The failed child this one was run again for, or empty.
      Retry_Of    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  The project's limits.
   --
   --  @param Item The store.
   --  @return The limits.
   function Limits_Of (Item : Stores.Store) return Limits;

   --  Make a root agent for a task: the harness is its owner.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Task_Id The task.
   --  @param Role Its role.
   --  @param Kind The task's kind, for its permissions.
   --  @param Id The agent.
   --  @param Status Framework_Limit_Exceeded when too many agents run.
   procedure Start_Root
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Task_Id : String;
      Role    : String;
      Kind    : String;
      Id      : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Make a child of an agent.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Parent The parent agent.
   --  @param Role The child's role.
   --  @param Need Whether the parent needs it.
   --  @param Asked The permissions asked for it.
   --  @param Budget The tokens it may use, out of the parent's.
   --  @param Retry_Of The failed child this one is run again for, or "": a
   --    run again is not one more child against the limit, and once it
   --    completes the failure it stands for no longer holds its parent.
   --  @param Id The child.
   --  @param Status Framework_Permission_Denied when the parent may not make
   --    children, Framework_Limit_Exceeded when a limit of depth, children,
   --    active agents or budget would be passed.
   procedure Spawn_Child
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Parent : String;
      Role   : String;
      Need   : Obligation;
      Asked  : Permissions.Permission_Set;
      Budget : Natural;
      Id     : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Model_Runner.Errors.Error_Info;
      Retry_Of : String := "");

   --  Read an agent.
   --
   --  @param Item The store.
   --  @param Id The agent.
   --  @param Result The agent.
   --  @param Status Framework_Not_Found when there is none.
   procedure Read
     (Item   : Stores.Store;
      Id     : String;
      Result : out Agent;
      Status : out Model_Runner.Errors.Error_Info);

   --  The children of an agent.
   --
   --  @param Item The store.
   --  @param Parent The agent.
   --  @return Their identifiers, in the order they were made.
   function Children
     (Item   : Stores.Store;
      Parent : String) return Name_Lists.Vector;

   --  Count what an agent used against its budget.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The agent.
   --  @param Tokens What it used now.
   --  @param Status Framework_Limit_Exceeded when that takes it past its
   --    budget; what it used is recorded either way.
   procedure Charge
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      Tokens : Natural;
      Status : out Model_Runner.Errors.Error_Info);

   --  Record how an agent ended, with its result: a reference and a
   --  summary. A required child that failed is recorded on its parent.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The agent.
   --  @param Succeeded Whether it did what it was for.
   --  @param Result_Id Its result; may be empty.
   --  @param Summary A line saying what it came to.
   --  @param Status Framework_Transition_Invalid when it has ended already.
   procedure Finish
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Id        : String;
      Succeeded : Boolean;
      Result_Id : String;
      Summary   : String;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Whether an agent may claim it is done: none of its required children
   --  still going or failed.
   --
   --  @param Item The store.
   --  @param Id The agent.
   --  @param Reason Why not, when not.
   --  @return True when it may.
   function May_Complete
     (Item   : Stores.Store;
      Id     : String;
      Reason : out Ada.Strings.Unbounded.Unbounded_String) return Boolean;

   --  Cancel an agent and, unless detached, every child of it still going.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The agent.
   --  @param Cancelled The agents cancelled, it first.
   --  @param Status A failure staging it.
   procedure Cancel
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Id        : String;
      Cancelled : out Name_Lists.Vector;
      Status    : out Model_Runner.Errors.Error_Info);

   --  What a parent is told of its children: each one's result reference
   --  and summary, one a line -- never what they said on the way.
   --
   --  @param Item The store.
   --  @param Parent The agent.
   --  @return The lines.
   function Child_Results (Item : Stores.Store; Parent : String) return String;

end Model_Runner.Framework.Agents;
