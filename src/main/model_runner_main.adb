--  SIGINT is reserved by the GNAT runtime unless a partition says otherwise.
--  model_runner attaches its own handler so that an interrupt requests a clean
--  cancellation -- releasing every resource and committing no cache position --
--  instead of terminating the process mid-token. This is a configuration
--  pragma and therefore belongs to the main unit of the partition.
pragma Unreserve_All_Interrupts;

with Ada.Command_Line;

with Model_Runner.CLI.Driver;

--  Entry point of the model_runner executable.
--
--  The main subprogram does nothing but hand the raw argument vector to the
--  command driver and set the process exit status. All argument interpretation,
--  localization, presentation and error mapping happens below, so that the
--  same code path can be exercised from the tests crate without a process.
procedure Model_Runner_Main is
   Status : Natural;
begin
   Model_Runner.CLI.Driver.Run_Process (Status);
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Exit_Status (Status));
end Model_Runner_Main;
