package body Model_Runner.Framework.Task_Workspaces is
   type Optional_Every_Active is access function
     (Item : Stores.Store; Task_Id : String) return Name_Lists.Vector;
   type Optional_Abandon is access procedure
     (Item : Stores.Store; Change : in out Stores.Transaction; Id : String;
      Status : out Model_Runner.Errors.Error_Info);
   type Optional_Conflicts is access function
     (Item : Stores.Store; Id : String; Unsettled_Only : Boolean;
      Project_Unchanged_Only : Boolean) return Name_Lists.Vector;
   Active_List : Optional_Every_Active := null;
   Active_Abandon : Optional_Abandon := null;
   Active_Conflicts : Optional_Conflicts := null;

   procedure Register
     (Every_Active : Every_Active_Checker; Abandon : Abandon_Action; Conflicts : Conflict_Checker) is
   begin
      Active_List := Optional_Every_Active (Every_Active);
      Active_Abandon := Optional_Abandon (Abandon);
      Active_Conflicts := Optional_Conflicts (Conflicts);
   end Register;

   function Every_Active (Item : Stores.Store; Task_Id : String) return Name_Lists.Vector is
     (if Active_List = null then Name_Lists.Empty_Vector else Active_List (Item, Task_Id));

   procedure Abandon
     (Item : Stores.Store; Change : in out Stores.Transaction; Id : String;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      if Active_Abandon = null then
         Status := Model_Runner.Errors.Success;
      else
         Active_Abandon (Item, Change, Id, Status);
      end if;
   end Abandon;

   function Conflict_Files (Item : Stores.Store; Id : String) return Name_Lists.Vector is
     (if Active_Conflicts = null then Name_Lists.Empty_Vector
      else Active_Conflicts (Item, Id, False, False));
end Model_Runner.Framework.Task_Workspaces;
