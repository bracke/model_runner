--  What a run of the suite under --only says, which is more than whether
--  every test passed: a name no test begins with runs none, and none
--  failing is not every one passing.
package Suite_Filter is

   type Verdict is (Passed, Failed, Matched_None);

   --  The verdict of one run.
   --
   --  @param Ran How many tests ran.
   --  @param Successful Whether none of them failed or raised.
   --  @param Only The name the run was narrowed to, or empty.
   --  @return Matched_None where a name was given and no test ran.
   function Judge
     (Ran        : Natural;
      Successful : Boolean;
      Only       : String) return Verdict
   is (if Only /= "" and then Ran = 0 then Matched_None
       elsif Successful then Passed
       else Failed);

end Suite_Filter;
