package body Model_Runner.Framework.Task_Eligibility is
   type Optional_Checker is access function
     (Item : Stores.Store; Task_Id : String) return String;
   Active : Optional_Checker := null;

   procedure Register (Value : Checker) is
   begin
      if Active /= null then
         raise Program_Error with "task eligibility service is already registered";
      end if;
      Active := Optional_Checker (Value);
   end Register;

   function Is_Available return Boolean is (Active /= null);

   function Unable_Reason (Item : Stores.Store; Task_Id : String) return String is
     (if Active = null then "execution eligibility service is not linked" else Active (Item, Task_Id));
end Model_Runner.Framework.Task_Eligibility;
