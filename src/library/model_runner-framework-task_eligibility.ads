with Model_Runner.Framework.Stores;

--  Execution-specific readiness supplied by the execution subsystem when linked.
package Model_Runner.Framework.Task_Eligibility is
   type Checker is not null access function
     (Item : Stores.Store; Task_Id : String) return String;
   procedure Register (Value : Checker);
   function Is_Available return Boolean;
   function Unable_Reason (Item : Stores.Store; Task_Id : String) return String;
end Model_Runner.Framework.Task_Eligibility;
