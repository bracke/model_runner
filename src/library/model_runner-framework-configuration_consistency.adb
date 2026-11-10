package body Model_Runner.Framework.Configuration_Consistency is
   type Optional_Checker is access function (Item : Stores.Store) return Result;
   Active : Optional_Checker := null;

   procedure Register (Value : Checker) is
   begin
      Active := Optional_Checker (Value);
   end Register;

   function Check (Item : Stores.Store) return Result is
     (if Active = null then (Findings => Name_Lists.Empty_Vector, Broken => False) else Active (Item));
end Model_Runner.Framework.Configuration_Consistency;
