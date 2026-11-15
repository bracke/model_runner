with Ada.Containers.Vectors;
with Ada.Real_Time;
with Ada.Strings.Unbounded;

with Model_Runner.Cancellation;
with Model_Runner.Code_Health.Diagnostics;
with Model_Runner.Errors;
with Model_Runner.Framework.Execution;

--  Deterministic adapters between Code Health and language-specific tools.
--  Providers receive bounded authority in an Analysis_Request; they do not
--  prompt a model, approve tool calls, or decide that a task is complete.
package Model_Runner.Code_Health.Providers is

   --  The only process capability visible to a provider. Framework-backed
   --  runners enforce Rules and bind execution to the owning transaction;
   --  tests can supply a deterministic implementation without a process.
   type Command_Runner is limited interface;
   type Command_Runner_Reference is access all Command_Runner'Class;

   procedure Run
     (Self      : in out Command_Runner;
      Rules     : Model_Runner.Framework.Execution.Policy;
      Command   : String;
      Directory : String;
      Deadline  : Ada.Real_Time.Time;
      Cancel    : Model_Runner.Cancellation.Token_Reference;
      Result    : out Model_Runner.Framework.Execution.Outcome;
      Status    : out Model_Runner.Errors.Error_Info) is abstract;

   type Check_Status is
     (Check_Not_Run,
      Check_Passed,
      Check_Findings,
      Check_Unavailable,
      Check_Timed_Out,
      Check_Cancelled,
      Check_Failed,
      Check_Stale);

   type Analysis_Request is record
      Project_Root       : Ada.Strings.Unbounded.Unbounded_String;
      Analysis_Root      : Ada.Strings.Unbounded.Unbounded_String;
      Change_Id          : Ada.Strings.Unbounded.Unbounded_String;
      Changed_Files      : String_Lists.Vector;
      Dependencies       : String_Lists.Vector;
      Affected_Tests     : String_Lists.Vector;
      Fallback_Test      : Ada.Strings.Unbounded.Unbounded_String;
      Level              : Check_Level := Fast;
      Configuration      : Ada.Strings.Unbounded.Unbounded_String;
      Deadline           : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Cancel             : Model_Runner.Cancellation.Token_Reference := null;
      Execution_Policy   : Model_Runner.Framework.Execution.Policy;
      Runner             : Command_Runner_Reference := null;
      Baseline_Id        : Ada.Strings.Unbounded.Unbounded_String;
      Task_Id            : Ada.Strings.Unbounded.Unbounded_String;
      Generation         : Natural := 0;
      Environment        : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Check_Result is record
      Identifier : Ada.Strings.Unbounded.Unbounded_String;
      Status     : Check_Status := Check_Not_Run;
      Required   : Boolean := True;
      Detail     : Ada.Strings.Unbounded.Unbounded_String;
      Evidence   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Check_Result_Lists is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Check_Result);

   type Analysis_Result is record
      Provider_Id              : Ada.Strings.Unbounded.Unbounded_String;
      Provider_Version         : Ada.Strings.Unbounded.Unbounded_String;
      Checks                   : Check_Result_Lists.Vector;
      Diagnostics              : Model_Runner.Code_Health.Diagnostics.Diagnostic_List;
      Files_Analyzed           : String_Lists.Vector;
      Input_Fingerprint        : Ada.Strings.Unbounded.Unbounded_String;
      Configuration_Fingerprint : Ada.Strings.Unbounded.Unbounded_String;
      Toolchain_Fingerprint    : Ada.Strings.Unbounded.Unbounded_String;
      Environment_Fingerprint  : Ada.Strings.Unbounded.Unbounded_String;
      Timed_Out                : Boolean := False;
      Cancelled                : Boolean := False;
      Exit_Status              : Integer := 0;
      Evidence                 : String_Lists.Vector;
      Duration                 : Standard.Duration := 0.0;
      Resource_Summary         : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Provider is limited interface;
   type Provider_Reference is access all Provider'Class;

   function Identifier (Self : Provider) return String is abstract;
   function Version (Self : Provider) return String is abstract;

   function Supports
     (Self  : Provider;
      Path  : String;
      Level : Check_Level) return Boolean is abstract;

   procedure Analyze
     (Self    : in out Provider;
      Request : Analysis_Request;
      Result  : out Analysis_Result;
      Status  : out Model_Runner.Errors.Error_Info) is abstract;

   --  A registry is explicit state so tests and concurrent harnesses do not
   --  depend on elaboration order or mutate one process-wide singleton.
   type Registry is tagged private;
   type Provider_List is private;

   procedure Register
     (Into   : in out Registry;
      Item   : not null Provider_Reference;
      Status : out Model_Runner.Errors.Error_Info);

   function Length (From : Registry) return Natural;
   function Length (From : Provider_List) return Natural;

   function Element
     (From  : Provider_List;
      Index : Positive) return Provider_Reference;

   function Contains
     (Within     : Registry;
      Identifier : String) return Boolean;

   function Find
     (Within     : Registry;
      Identifier : String) return Provider_Reference;

   --  Every applicable provider, sorted by identifier regardless of the
   --  order in which providers were registered.
   function Select_Providers
     (From  : Registry;
      Path  : String;
      Level : Check_Level) return Provider_List;

   function Valid_Identifier (Value : String) return Boolean;
   function Valid_Version (Value : String) return Boolean;

private

   package Provider_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Provider_Reference);

   type Registry is tagged record
      Items : Provider_Vectors.Vector;
   end record;

   type Provider_List is record
      Items : Provider_Vectors.Vector;
   end record;

end Model_Runner.Code_Health.Providers;
