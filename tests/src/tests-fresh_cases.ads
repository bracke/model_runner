with AUnit.Test_Cases;

--  The case every suite's case derives from: before each routine the
--  process-wide settings a routine may change are put back as the program
--  starts with them, so no routine's answer depends on which ran before it.
--  The processor's arithmetic is one such setting -- which roles of weight
--  multiply inexactly -- and a test of exact agreement passed or failed by
--  what a test before it had left set.
package Tests.Fresh_Cases is

   type Fresh_Case is abstract new AUnit.Test_Cases.Test_Case with null record;

   --  Put the settings back.
   --
   --  @param T The case about to run a routine.
   overriding procedure Set_Up (T : in out Fresh_Case);

end Tests.Fresh_Cases;
