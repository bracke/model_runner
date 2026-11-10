package body Model_Runner.Framework.Task_Eligibility is
   type Optional_Checker is access function
     (Item : Stores.Store; Task_Id : String) return String;
   Active : Optional_Checker := null;

   procedure Register (Value : Checker) is
   begin
      Active := Optional_Checker (Value);
   end Register;

   function Unable_Reason (Item : Stores.Store; Task_Id : String) return String is
     (if Active = null then "" else Active (Item, Task_Id));
end Model_Runner.Framework.Task_Eligibility;
