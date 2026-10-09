package body Model_Runner.Tools.Runner is

   ---------
   -- Run --
   ---------

   procedure Run
     (Self      : in out Instance'Class;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      Ended : Call_Outcome;
   begin
      Self.Run (Named, Arguments, Result, Last, Ended, Status);
   end Run;

end Model_Runner.Tools.Runner;
