with Model_Runner.Errors;

--  Versioned noninteractive adapter over the native Framework.Work engine.
package Model_Runner.CLI.Headless_Work is

   --  Describe the supported schema and operations.
   --
   --  @return Schema-versioned JSON capabilities.
   function Capabilities return String;

   --  Inspect one native task and the exact identities required for dispatch.
   --
   --  @param Project_Directory Initialized model_runner project.
   --  @param Task_Id Exact native task identity.
   --  @param Status Read or compatibility failure.
   --  @return Schema-versioned JSON task snapshot or error.
   function Inspect_Task
     (Project_Directory : String;
      Task_Id           : String;
      Status            : out Model_Runner.Errors.Error_Info) return String;

   --  Execute one exact task through the native work engine.
   --
   --  The operation identity is durable. Repeating the exact request returns
   --  its recorded outcome without starting another agent.
   function Execute_Task
     (Project_Directory          : String;
      Task_Id                    : String;
      Operation_Id               : String;
      Expected_Task_Revision     : String;
      Expected_Project_Identity  : String;
      Expected_Source_Fingerprint : String;
      Execution_Policy           : String;
      Timeout_Seconds            : Natural;
      Status                     : out Model_Runner.Errors.Error_Info) return String;

   --  Read one durable operation without changing native work.
   function Operation_Status
     (Project_Directory : String;
      Operation_Id      : String;
      Status            : out Model_Runner.Errors.Error_Info) return String;

   --  Handle a top-level `model_runner work` command from Ada.Command_Line.
   --
   --  @param Status Process exit status.
   procedure Run_Process (Status : out Natural);

end Model_Runner.CLI.Headless_Work;
