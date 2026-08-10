with Model_Runner.Errors;

--  Diagnostics the program raises that no test reaches.
--
--  Reserved_Codes names the codes nothing raises at all, and the repository
--  checks hold that list in both directions. Between "declared" and "raised"
--  there was a third state nobody had named: raised on a path no test walks.
--  Seventeen codes were in it, and nothing said so -- the check asks whether
--  a code appears in the source, and a raise nobody reaches appears there
--  exactly as a raise everybody reaches does.
--
--  What that hides is a refusal that does not work. A code is a promise that
--  a particular wrong input is turned away and named; the raise being written
--  is not evidence that the branch is taken, and several here guard paths
--  that had never been walked at all.
--
--  This is the list that remains, each with why it is not reached, and the
--  checks hold it in both directions: a code that becomes tested fails until
--  it is taken off, and one that stops being tested fails until it is put on.
--
--  Task safety: pure.
package Unreached_Codes is

   --  Report whether a code is one no test reaches.
   --
   --  @param Code Diagnostic to classify.
   --  @return True when it is on the list.
   function Is_Unreached
     (Code : Model_Runner.Errors.Error_Code) return Boolean;

   --  How many codes the list holds.
   --
   --  @return Count.
   function Count return Natural;

end Unreached_Codes;
