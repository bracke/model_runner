with Model_Runner.Framework.Stores;

--  Execution-specific readiness supplied by the execution subsystem when linked.
package Model_Runner.Framework.Task_Eligibility is
   --  The check the execution subsystem supplies: why a task cannot run,
   --  or empty.
   type Checker is not null access function
     (Item : Stores.Store; Task_Id : String) return String;

   --  Make Value the check Unable_Reason runs; a second registration is
   --  refused.
   --
   --  @param Value The check.
   procedure Register (Value : Checker);

   --  Whether a check has been registered.
   --
   --  @return True once Register has run.
   function Is_Available return Boolean;

   --  Why a task cannot run, or empty where it can.
   --
   --  @param Item The project's store.
   --  @param Task_Id The task.
   --  @return The reason, or empty; where no check is linked, that it is
   --    not.
   function Unable_Reason (Item : Stores.Store; Task_Id : String) return String;
end Model_Runner.Framework.Task_Eligibility;
