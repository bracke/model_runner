with Ada.Strings.Unbounded;

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
      if Active_List /= null or else Active_Abandon /= null or else Active_Conflicts /= null then
         raise Program_Error with "task workspace lifecycle service is already registered";
      end if;
      Active_List := Optional_Every_Active (Every_Active);
      Active_Abandon := Optional_Abandon (Abandon);
      Active_Conflicts := Optional_Conflicts (Conflicts);
   end Register;

   function Is_Available return Boolean is
     (Active_List /= null and then Active_Abandon /= null and then Active_Conflicts /= null);

   function Every_Active (Item : Stores.Store; Task_Id : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      if Active_List /= null then
         return Active_List (Item, Task_Id);
      end if;
      --  A publication-only consumer cannot abandon a workspace, but it can
      --  inspect the two fields needed to refuse a transition that would
      --  strand one. Unreadable records are conservatively treated as active.
      for Name of Stores.Names (Item, Workspaces_Area) loop
         declare
            Task_Name : Ada.Strings.Unbounded.Unbounded_String;
            State  : Ada.Strings.Unbounded.Unbounded_String;
            Status : Model_Runner.Errors.Error_Info;

            procedure Keep (Field, Value : String) is
            begin
               if Field = "task" then
                  Task_Name := Ada.Strings.Unbounded.To_Unbounded_String (Value);
               elsif Field = "status" then
                  State := Ada.Strings.Unbounded.To_Unbounded_String (Value);
               end if;
            end Keep;
         begin
            Stores.Read_Fields (Item, Workspaces_Area, Name, Keep'Access, Status);
            if Model_Runner.Errors.Is_Error (Status) or else
              (Ada.Strings.Unbounded.To_String (Task_Name) = Task_Id and then
               Ada.Strings.Unbounded.To_String (State) = "active")
            then
               Result.Append (Name);
            end if;
         end;
      end loop;
      return Result;
   end Every_Active;

   procedure Abandon
     (Item : Stores.Store; Change : in out Stores.Transaction; Id : String;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      if Active_Abandon = null then
         Status := Model_Runner.Errors.Make (Model_Runner.Errors.Framework_Workspace_Failed);
         Model_Runner.Errors.Add_Text (Status, "name", Id);
         Model_Runner.Errors.Add_Text (Status, "detail", "workspace lifecycle service is not linked");
      else
         Active_Abandon (Item, Change, Id, Status);
      end if;
   end Abandon;

   function Conflict_Files (Item : Stores.Store; Id : String) return Name_Lists.Vector is
   begin
      if not Is_Available then
         raise Program_Error with "task workspace lifecycle service is not linked";
      end if;
      return Active_Conflicts (Item, Id, False, False);
   end Conflict_Files;
end Model_Runner.Framework.Task_Workspaces;
