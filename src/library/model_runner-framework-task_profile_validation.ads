with Model_Runner.Framework.Stores;

--  Optional inference-profile validation supplied by the operational runner.
package Model_Runner.Framework.Task_Profile_Validation is
   --  The validation the runner supplies: what is wrong with a profile,
   --  or empty.
   type Validator is not null access function (Item : Stores.Store; Value : String) return String;

   --  Make Value the validation Problem runs; a second registration is
   --  refused.
   --
   --  @param Value The validation.
   procedure Register (Value : Validator);

   --  What is wrong with an inference profile, or empty where nothing is.
   --
   --  @param Item The project's store.
   --  @param Value The profile named.
   --  @return The problem, or empty; where no validation is linked, that
   --    it is not.
   function Problem (Item : Stores.Store; Value : String) return String;
end Model_Runner.Framework.Task_Profile_Validation;
