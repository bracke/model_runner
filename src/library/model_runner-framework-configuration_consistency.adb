package body Model_Runner.Framework.Configuration_Consistency is
   type Optional_Checker is access function (Item : Stores.Store) return Result;
   Active : Optional_Checker := null;

   procedure Register (Value : Checker) is
   begin
      if Active /= null then
         raise Program_Error with "configuration consistency service is already registered";
      end if;
      Active := Optional_Checker (Value);
   end Register;

   function Is_Available return Boolean is (Active /= null);

   function Check (Item : Stores.Store) return Result is
   begin
      if Active = null then
         return
           (Findings => Name_Lists.To_Vector ("whole-project consistency service is not linked", 1),
            Broken   => True);
      end if;
      return Active (Item);
   end Check;
end Model_Runner.Framework.Configuration_Consistency;
