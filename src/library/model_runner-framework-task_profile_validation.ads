with Model_Runner.Framework.Stores;

--  Optional inference-profile validation supplied by the operational runner.
package Model_Runner.Framework.Task_Profile_Validation is
   type Validator is not null access function (Item : Stores.Store; Value : String) return String;

   procedure Register (Value : Validator);

   function Problem (Item : Stores.Store; Value : String) return String;
end Model_Runner.Framework.Task_Profile_Validation;
