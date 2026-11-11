with Model_Runner.Framework.Stores;

--  Whole-project checks supplied by Consistency when the operational
--  framework is linked. Publication-only consumers do not initialize state.
package Model_Runner.Framework.Configuration_Consistency is
   --  What a whole-project check found, and whether it found the
   --  configuration broken.
   type Result is record
      Findings : Name_Lists.Vector;
      Broken   : Boolean := False;
   end record;

   --  The check Consistency supplies.
   type Checker is not null access function (Item : Stores.Store) return Result;

   --  Make Value the check Check runs.
   --
   --  @param Value The check.
   procedure Register (Value : Checker);

   --  Whether a check has been registered.
   --
   --  @return True once Register has run.
   function Is_Available return Boolean;

   --  Run the registered check over a store.
   --
   --  @param Item The store to check.
   --  @return What the check found.
   function Check (Item : Stores.Store) return Result;
end Model_Runner.Framework.Configuration_Consistency;
