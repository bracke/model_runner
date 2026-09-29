with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Where an agent writes, apart from the project until its work is taken in.
--
--  A workspace is a copy of the project for one agent on one task in one
--  execution generation: a Git worktree when the project is a Git
--  repository and Git is there, a copy of its files otherwise. Its files as
--  they were made are its baseline, kept with the record. What the agent
--  changed is what differs from the baseline; a conflict is a file it
--  changed that the project has changed too since the baseline was taken.
--
--  Taking the work in is the harness's: it needs its own permission --
--  having written is not having the right to integrate -- and it is refused,
--  naming the files, when there is a conflict. A semantic conflict -- no
--  file on both sides, but a unit changed on both, or a unit the agent
--  changed depending on one the project changed or depended on by it -- is
--  escalated the same way, for a person to take in anyway or not; text
--  alone would have merged it. Integration copies the
--  changed files into the project and removes the ones the agent removed;
--  what is verified afterwards is the project as it now is, not the
--  workspace.
package Model_Runner.Framework.Workspaces is

   --  How a workspace is kept.
   type Backend is (Git_Worktree, File_Copy);

   --  One workspace, as recorded.
   type Workspace is record
      Id         : Ada.Strings.Unbounded.Unbounded_String;
      Kind       : Backend := File_Copy;
      Path       : Ada.Strings.Unbounded.Unbounded_String;
      Base       : Ada.Strings.Unbounded.Unbounded_String;
      Agent      : Ada.Strings.Unbounded.Unbounded_String;
      Task_Id    : Ada.Strings.Unbounded.Unbounded_String;
      Generation : Ada.Strings.Unbounded.Unbounded_String;
      Status     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Make a workspace for an agent's work on a task.
   --
   --  @param Item The store.
   --  @param Change The transaction its record is staged in.
   --  @param Task_Id The task.
   --  @param Agent The agent that owns it.
   --  @param Generation The task's execution generation.
   --  @param Prefer_Git Whether to use a Git worktree when the project is a
   --    Git repository.
   --  @param Result The workspace.
   --  @param Status Framework_Workspace_Failed when it cannot be made.
   procedure Create
     (Item       : Stores.Store;
      Change     : in out Stores.Transaction;
      Task_Id    : String;
      Agent      : String;
      Generation : String;
      Prefer_Git : Boolean;
      Result     : out Workspace;
      Status     : out Model_Runner.Errors.Error_Info);

   --  Read a workspace's record.
   --
   --  @param Item The store.
   --  @param Id The workspace.
   --  @param Result The workspace.
   --  @param Status Framework_Not_Found when there is none.
   procedure Read
     (Item   : Stores.Store;
      Id     : String;
      Result : out Workspace;
      Status : out Model_Runner.Errors.Error_Info);

   --  The workspace a task's work is in, if one is active.
   --
   --  @param Item The store.
   --  @param Task_Id The task.
   --  @return Its identifier, or the empty string.
   function Active_For (Item : Stores.Store; Task_Id : String) return String;

   --  The files an agent changed in its workspace, against the baseline.
   --
   --  @param Item The store.
   --  @param Id The workspace.
   --  @return Their paths within the project, sorted.
   function Changes (Item : Stores.Store; Id : String) return Name_Lists.Vector;

   --  The files changed in the workspace that the project has changed too
   --  since the baseline.
   --
   --  @param Item The store.
   --  @param Id The workspace.
   --  @return Their paths, sorted.
   function Conflicts (Item : Stores.Store; Id : String) return Name_Lists.Vector;

   --  The workspace's changes that the project's own changes since the
   --  baseline reach through the code, with no file in both: a unit
   --  changed on both sides, a unit changed here depending on one changed
   --  there, or one changed there depending on one changed here. Found by
   --  the repository graphs, so as sure as they are.
   --
   --  @param Item The store.
   --  @param Id The workspace.
   --  @return Each as the workspace's file, the project's and why.
   function Semantic_Conflicts (Item : Stores.Store; Id : String) return Name_Lists.Vector;

   --  Remove an integrated workspace's tree, once its integration is
   --  kept: until then the work is still there to take in again.
   --
   --  @param Item The store.
   --  @param Id The workspace.
   procedure Release (Item : Stores.Store; Id : String);

   --  Take a workspace's changes into the project.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The workspace.
   --  @param Permitted Whether whoever asks has the right to integrate.
   --  @param Taken The files integrated.
   --  @param Status Framework_Integration_Refused without the right,
   --    Framework_Integration_Conflict naming the files in conflict, or
   --    the semantic conflicts when they are not accepted,
   --    Framework_Transition_Invalid when it is not active.
   --  @param Semantic_Accepted Whether a person has seen the semantic
   --    conflicts and takes the work in anyway.
   --  @param Text_Resolved Whether a person has settled the conflicts of
   --    text in the workspace's files, which are then taken over the
   --    project's.
   procedure Integrate
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Id        : String;
      Permitted : Boolean;
      Taken     : out Name_Lists.Vector;
      Status    : out Model_Runner.Errors.Error_Info;
      Semantic_Accepted : Boolean := False;
      Text_Resolved     : Boolean := False);

   --  Give a workspace up: its files removed and its record marked
   --  abandoned.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The workspace.
   --  @param Status Framework_Not_Found when there is none.
   procedure Abandon
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      Status : out Model_Runner.Errors.Error_Info);

end Model_Runner.Framework.Workspaces;
