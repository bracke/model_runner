with Ada.Real_Time;

with Model_Runner.Cancellation;
with Model_Runner.Code_Health.Diagnostics;
with Model_Runner.Code_Health.Providers;
with Model_Runner.Errors;

--  Native Ada analysis. External programs are reached only through the
--  provider request's policy-bound runner; shared source measurements are
--  supplied by an adapter owned by ada_quality.
package Model_Runner.Code_Health.Ada is

   package P renames Model_Runner.Code_Health.Providers;
   package D renames Model_Runner.Code_Health.Diagnostics;

   type Source_Analysis is record
      Check                 : P.Check_Result;
      Diagnostics           : D.Diagnostic_List;
      Files_Analyzed        : String_Lists.Vector;
      Toolchain_Fingerprint : String_Lists.Vector;
   end record;

   type Source_Analyzer is limited interface;
   type Source_Analyzer_Reference is access all Source_Analyzer'Class;

   --  @param Self Source analyzer.
   --  @return Semantic analyzer version.
   function Version (Self : Source_Analyzer) return String is abstract;

   --  @param Self Source analyzer.
   --  @param Project_Root Canonical project root.
   --  @param Changed Project-relative changed sources.
   --  @param Configuration Configuration fingerprint.
   --  @param Snapshot Immutable input identifier.
   --  @param Deadline Owning assessment deadline.
   --  @param Cancel Owning cancellation token.
   --  @param Result Normalized source analysis.
   --  @param Status Success or analysis failure.
   procedure Analyze_Changed_Sources
     (Self          : in out Source_Analyzer;
      Project_Root  : String;
      Changed       : String_Lists.Vector;
      Configuration : String;
      Snapshot      : String;
      Deadline      : Standard.Ada.Real_Time.Time;
      Cancel        : Model_Runner.Cancellation.Token_Reference;
      Result        : out Source_Analysis;
      Status        : out Model_Runner.Errors.Error_Info) is abstract;

   type Instance is limited new P.Provider and P.Cache_Aware_Provider with private;

   --  @param Self Ada provider to initialize.
   --  @param Source_Checker Optional shared source-quality adapter.
   --  @param Language_Checker Optional editor-diagnostic adapter.
   procedure Initialize
     (Self           : in out Instance;
      Source_Checker : Source_Analyzer_Reference := null;
      Language_Checker : Source_Analyzer_Reference := null);

   --  @param Self Ada provider.
   --  @return Provider identifier.
   overriding function Identifier (Self : Instance) return String;

   --  @param Self Ada provider.
   --  @return Provider version.
   overriding function Version (Self : Instance) return String;

   overriding function Supports
     (Self  : Instance;
      Path  : String;
      Level : Check_Level) return Boolean;

   overriding procedure Analyze
     (Self    : in out Instance;
      Request : P.Analysis_Request;
      Result  : out P.Analysis_Result;
      Status  : out Model_Runner.Errors.Error_Info);

   overriding procedure Probe_Cache
     (Self    : in out Instance;
      Request : P.Analysis_Request;
      Result  : out P.Cache_Probe;
      Status  : out Model_Runner.Errors.Error_Info);

private

   type Instance is limited new P.Provider and P.Cache_Aware_Provider with record
      Source_Checker   : Source_Analyzer_Reference := null;
      Language_Checker : Source_Analyzer_Reference := null;
   end record;

end Model_Runner.Code_Health.Ada;
