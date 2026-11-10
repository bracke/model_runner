with Model_Runner.Framework.Stores;

--  Whole-project checks supplied by Consistency when the operational
--  framework is linked. Publication-only consumers do not initialize state.
package Model_Runner.Framework.Configuration_Consistency is
   type Result is record
      Findings : Name_Lists.Vector;
      Broken   : Boolean := False;
   end record;

   type Checker is not null access function (Item : Stores.Store) return Result;
   procedure Register (Value : Checker);
   function Is_Available return Boolean;
   function Check (Item : Stores.Store) return Result;
end Model_Runner.Framework.Configuration_Consistency;
