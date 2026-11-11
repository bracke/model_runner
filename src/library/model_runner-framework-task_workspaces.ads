with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Workspace effects supplied by the execution subsystem when linked.
package Model_Runner.Framework.Task_Workspaces is
   --  The workspaces of a task still active, as the subsystem lists them.
   type Every_Active_Checker is not null access function
     (Item : Stores.Store; Task_Id : String) return Name_Lists.Vector;
   --  Abandoning a workspace, as the subsystem does it.
   type Abandon_Action is not null access procedure
     (Item : Stores.Store; Change : in out Stores.Transaction; Id : String;
      Status : out Model_Runner.Errors.Error_Info);
   --  The files of a workspace that conflict, as the subsystem finds them.
   type Conflict_Checker is not null access function
     (Item : Stores.Store; Id : String; Unsettled_Only : Boolean;
      Project_Unchanged_Only : Boolean) return Name_Lists.Vector;
   --  Make these the workspace effects the operations below run.
   --
   --  @param Every_Active Lists a task's active workspaces.
   --  @param Abandon Abandons a workspace.
   --  @param Conflicts Finds a workspace's conflicting files.
   procedure Register
     (Every_Active : Every_Active_Checker; Abandon : Abandon_Action; Conflicts : Conflict_Checker);

   --  Whether the effects have been registered.
   --
   --  @return True once Register has run.
   function Is_Available return Boolean;

   --  A task's workspaces still active; without the subsystem, read from
   --  the records, an unreadable one counted as active.
   --
   --  @param Item The project's store.
   --  @param Task_Id The task.
   --  @return The workspaces.
   function Every_Active (Item : Stores.Store; Task_Id : String) return Name_Lists.Vector;

   --  Abandon a workspace within a change.
   --
   --  @param Item The project's store.
   --  @param Change The transaction it is part of.
   --  @param Id The workspace.
   --  @param Status Success, or why not; a failure where the subsystem is
   --    not linked.
   procedure Abandon
     (Item : Stores.Store; Change : in out Stores.Transaction; Id : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  The files of a workspace that conflict with the project.
   --
   --  @param Item The project's store.
   --  @param Id The workspace.
   --  @return The files.
   function Conflict_Files (Item : Stores.Store; Id : String) return Name_Lists.Vector;
end Model_Runner.Framework.Task_Workspaces;
