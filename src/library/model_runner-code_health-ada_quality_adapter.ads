with Model_Runner.Code_Health.Ada;
with Model_Runner.Errors;

--  Change-scoped bridge to ada_quality's authoritative native indicators.
package Model_Runner.Code_Health.Ada_Quality_Adapter is

   type Instance is limited new Model_Runner.Code_Health.Ada.Source_Analyzer with null record;

   overriding function Version (Self : Instance) return String;

   overriding procedure Analyze_Changed_Sources
     (Self          : in out Instance;
      Project_Root  : String;
      Changed       : String_Lists.Vector;
      Configuration : String;
      Snapshot      : String;
      Result        : out Model_Runner.Code_Health.Ada.Source_Analysis;
      Status        : out Model_Runner.Errors.Error_Info);

end Model_Runner.Code_Health.Ada_Quality_Adapter;
