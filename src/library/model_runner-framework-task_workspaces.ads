with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Workspace effects supplied by the execution subsystem when linked.
package Model_Runner.Framework.Task_Workspaces is
   type Every_Active_Checker is not null access function
     (Item : Stores.Store; Task_Id : String) return Name_Lists.Vector;
   type Abandon_Action is not null access procedure
     (Item : Stores.Store; Change : in out Stores.Transaction; Id : String;
      Status : out Model_Runner.Errors.Error_Info);
   type Conflict_Checker is not null access function
     (Item : Stores.Store; Id : String; Unsettled_Only : Boolean;
      Project_Unchanged_Only : Boolean) return Name_Lists.Vector;
   procedure Register
     (Every_Active : Every_Active_Checker; Abandon : Abandon_Action; Conflicts : Conflict_Checker);
   function Is_Available return Boolean;
   function Every_Active (Item : Stores.Store; Task_Id : String) return Name_Lists.Vector;
   procedure Abandon
     (Item : Stores.Store; Change : in out Stores.Transaction; Id : String;
      Status : out Model_Runner.Errors.Error_Info);
   function Conflict_Files (Item : Stores.Store; Id : String) return Name_Lists.Vector;
end Model_Runner.Framework.Task_Workspaces;
