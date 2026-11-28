with AUnit.Test_Cases;
with Ada.Strings.Unbounded;

--  The case every suite's case derives from: before each routine the
--  process-wide settings a routine may change are put back as the program
--  starts with them, so no routine's answer depends on which ran before it.
--  The processor's arithmetic is one such setting -- which roles of weight
--  multiply inexactly -- and a test of exact agreement passed or failed by
--  what a test before it had left set.
package Tests.Fresh_Cases is

   type Fresh_Case is abstract new AUnit.Test_Cases.Test_Case with record
      Directory : Ada.Strings.Unbounded.Unbounded_String;
      Config : Ada.Strings.Unbounded.Unbounded_String;
      Had_Config : Boolean := False;
   end record;

   --  Put the settings back.
   --
   --  @param T The case about to run a routine.
   overriding procedure Set_Up (T : in out Fresh_Case);

   --  Restore the caller's directory and settings-file selection even when
   --  a routine fails, so later tests still address their own fixtures.
   --
   --  @param T The case whose routine has finished.
   overriding procedure Tear_Down (T : in out Fresh_Case);

end Tests.Fresh_Cases;
