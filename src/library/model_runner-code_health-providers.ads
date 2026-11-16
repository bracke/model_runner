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

   --  @param Self Authorized runner.
   --  @param Rules Requested policy, intersected with its authority.
   --  @param Command Program and arguments.
   --  @param Directory Confined working directory.
   --  @param Deadline Execution deadline.
   --  @param Cancel Owning cancellation token.
   --  @param Result Process outcome.
   --  @param Status Success or operational failure.
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

   --  The source extent a selected check is authorized and required to
   --  inspect.  Providers must not silently widen Changed_Files, and must
   --  report when a dependency scope cannot be established reliably.
   type Scope_Kind is
     (Changed_Files,
      Dependency_Scope,
      Whole_Project);

   --  One check selected by the validated profile.  Providers may omit a
   --  selected check only when it is inapplicable to every requested input.
   type Requested_Check is record
      Identifier        : Ada.Strings.Unbounded.Unbounded_String;
      Provider          : Ada.Strings.Unbounded.Unbounded_String;
      Required          : Boolean := True;
      Block_On          : Diagnostic_Severity := Error;
      Scope             : Scope_Kind := Changed_Files;
      Timeout_Seconds   : Natural := 10;
      Dependencies      : String_Lists.Vector;
      Cacheable         : Boolean := True;
      Tool_Requirements : String_Lists.Vector;
      Output_Limit      : Natural := 8 * 1024;
   end record;

   package Requested_Check_Lists is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Requested_Check);

   type Analysis_Request is record
      Project_Root       : Ada.Strings.Unbounded.Unbounded_String;
      Analysis_Root      : Ada.Strings.Unbounded.Unbounded_String;
      Change_Id          : Ada.Strings.Unbounded.Unbounded_String;
      Changed_Files      : String_Lists.Vector;
      Project_Files      : String_Lists.Vector;
      Dependencies       : String_Lists.Vector;
      Affected_Tests     : String_Lists.Vector;
      Affected_Test_Directories : String_Lists.Vector;
      Fallback_Test      : Ada.Strings.Unbounded.Unbounded_String;
      Level              : Check_Level := Fast;
      Checks             : Requested_Check_Lists.Vector;
      Configuration      : Ada.Strings.Unbounded.Unbounded_String;
      Started            : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
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

   --  Optional provider capability for proving that persisted results still
   --  have exactly the same configuration, toolchain and environment.
   --  Providers without this interface are always executed.
   type Cache_Aware_Provider is limited interface;

   type Cache_Probe is record
      Reusable                  : Boolean := False;
      Configuration_Fingerprint : Ada.Strings.Unbounded.Unbounded_String;
      Toolchain_Fingerprint     : Ada.Strings.Unbounded.Unbounded_String;
      Environment_Fingerprint   : Ada.Strings.Unbounded.Unbounded_String;
      Detail                    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Probe only the prerequisites needed to validate a cache key.  It may
   --  inspect authorized tool versions but must not perform the analysis.
   --  @param Self Cache-aware provider.
   --  @param Request Immutable bounded request.
   --  @param Result Reuse decision and current fingerprints.
   --  @param Status Success or operational failure.
   procedure Probe_Cache
     (Self    : in out Cache_Aware_Provider;
      Request : Analysis_Request;
      Result  : out Cache_Probe;
      Status  : out Model_Runner.Errors.Error_Info) is abstract;

   --  Contain exceptions and reject incomplete reusable fingerprints.
   --  @param Self Cache-aware provider.
   --  @param Request Immutable bounded request.
   --  @param Result Validated reuse decision and current fingerprints.
   --  @param Status Success or contained provider failure.
   procedure Probe_Cache_Safely
     (Self    : in out Cache_Aware_Provider'Class;
      Request : Analysis_Request;
      Result  : out Cache_Probe;
      Status  : out Model_Runner.Errors.Error_Info);

   --  @param Self Provider.
   --  @return Stable provider identifier.
   function Identifier (Self : Provider) return String is abstract;

   --  @param Self Provider.
   --  @return Stable semantic version.
   function Version (Self : Provider) return String is abstract;

   --  @param Self Provider.
   --  @param Path Project-relative path.
   --  @param Level Requested analysis level.
   --  @return Whether this provider applies.
   function Supports
     (Self  : Provider;
      Path  : String;
      Level : Check_Level) return Boolean is abstract;

   --  @param Self Provider.
   --  @param Request Immutable bounded request.
   --  @param Result Normalized result.
   --  @param Status Success or operational failure.
   procedure Analyze
     (Self    : in out Provider;
      Request : Analysis_Request;
      Result  : out Analysis_Result;
      Status  : out Model_Runner.Errors.Error_Info) is abstract;

   --  Validate the complete result at the trust boundary before it can be
   --  rendered or persisted.  Expected values are optional for callers
   --  validating stored data; the live dispatcher supplies all of them.
   --  @param Item Result to validate.
   --  @param Status Success or structural violation.
   --  @param Expected_Provider Required provider identity, when known.
   --  @param Expected_Version Required provider version, when known.
   --  @param Expected_Snapshot Required snapshot, when known.
   --  @param Project_Root Root used to confine diagnostic paths.
   procedure Validate_Result
     (Item             : Analysis_Result;
      Status           : out Model_Runner.Errors.Error_Info;
      Expected_Provider : String := "";
      Expected_Version : String := "";
      Expected_Snapshot : String := "";
      Project_Root     : String := "");

   --  Invoke a provider without allowing an exception or malformed result
   --  to escape into the owning agent session.  Operational provider errors
   --  remain errors; Result is replaced with a non-passing synthetic check.
   --  @param Self Provider to invoke.
   --  @param Request Immutable bounded request.
   --  @param Result Validated or synthetic non-passing result.
   --  @param Status Success or contained provider failure.
   procedure Analyze_Safely
     (Self    : in out Provider'Class;
      Request : Analysis_Request;
      Result  : out Analysis_Result;
      Status  : out Model_Runner.Errors.Error_Info);

   --  A registry is explicit state so tests and concurrent harnesses do not
   --  depend on elaboration order or mutate one process-wide singleton.
   type Registry is tagged private;
   type Provider_List is private;

   --  @param Into Registry to update.
   --  @param Item Provider to register.
   --  @param Status Success or duplicate/invalid provider failure.
   procedure Register
     (Into   : in out Registry;
      Item   : not null Provider_Reference;
      Status : out Model_Runner.Errors.Error_Info);

   --  @param From Registry.
   --  @return Number of providers.
   function Length (From : Registry) return Natural;

   --  @param From Provider list.
   --  @return Number of providers.
   function Length (From : Provider_List) return Natural;

   --  @param From Provider list.
   --  @param Index One-based index.
   --  @return Provider reference.
   function Element
     (From  : Provider_List;
      Index : Positive) return Provider_Reference;

   --  @param Within Registry.
   --  @param Identifier Provider identifier.
   --  @return Whether it is registered.
   function Contains
     (Within     : Registry;
      Identifier : String) return Boolean;

   --  @param Within Registry.
   --  @param Identifier Provider identifier.
   --  @return Provider reference, or null.
   function Find
     (Within     : Registry;
      Identifier : String) return Provider_Reference;

   --  Every applicable provider, sorted by identifier regardless of the
   --  order in which providers were registered.
   --  @param From Registry.
   --  @param Path Project-relative path.
   --  @param Level Requested level.
   --  @return Deterministically ordered applicable providers.
   function Select_Providers
     (From  : Registry;
      Path  : String;
      Level : Check_Level) return Provider_List;

   --  @param Value Candidate identifier.
   --  @return Whether it is valid.
   function Valid_Identifier (Value : String) return Boolean;

   --  @param Value Candidate version.
   --  @return Whether it is valid.
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
