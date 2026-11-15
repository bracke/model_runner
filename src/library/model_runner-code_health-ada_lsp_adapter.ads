with Model_Runner.Code_Health.Ada;
with Model_Runner.Errors;

--  Normalizes the existing interactive language-server diagnostics as one
--  optional input to the native Ada provider.
package Model_Runner.Code_Health.Ada_LSP_Adapter is

   type Instance is limited new Model_Runner.Code_Health.Ada.Source_Analyzer with null record;

   overriding function Version (Self : Instance) return String;

   procedure Normalize_Problems
     (Path     : String;
      Problems : String;
      Snapshot : String;
      Result   : out Model_Runner.Code_Health.Ada.Source_Analysis;
      Status   : out Model_Runner.Errors.Error_Info);

   overriding procedure Analyze_Changed_Sources
     (Self          : in out Instance;
      Project_Root  : String;
      Changed       : String_Lists.Vector;
      Configuration : String;
      Snapshot      : String;
      Result        : out Model_Runner.Code_Health.Ada.Source_Analysis;
      Status        : out Model_Runner.Errors.Error_Info);

end Model_Runner.Code_Health.Ada_LSP_Adapter;
