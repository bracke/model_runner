package body Model_Runner.Framework.Task_Profile_Validation is
   type Optional_Validator is access function (Item : Stores.Store; Value : String) return String;
   Active : Optional_Validator := null;

   procedure Register (Value : Validator) is
   begin
      if Active /= null then
         raise Program_Error with "task inference-profile validator is already registered";
      end if;
      Active := Optional_Validator (Value);
   end Register;

   function Problem (Item : Stores.Store; Value : String) return String is
     (if Active = null then "inference-profile validation is not linked" else Active (Item, Value));
end Model_Runner.Framework.Task_Profile_Validation;
