with Ada.Real_Time;

with Model_Runner.Cancellation;
with Model_Runner.Code_Health.Ada;
with Model_Runner.Errors;

--  Normalizes the existing interactive language-server diagnostics as one
--  optional input to the native Ada provider.
package Model_Runner.Code_Health.Ada_LSP_Adapter is

   type Problem_Source is access function
     (Path : String;
      Wait : Duration) return String;

   type Instance is limited new Model_Runner.Code_Health.Ada.Source_Analyzer with private;

   --  @param Self Adapter receiving the callback.
   --  @param Source CLI-owned diagnostic source, or null to disable it.
   procedure Use_Source
     (Self   : in out Instance;
      Source : Problem_Source);

   --  @param Self Adapter.
   --  @return Adapter version.
   overriding function Version (Self : Instance) return String;

   --  @param Path Project-relative source path.
   --  @param Problems Bounded language-server text.
   --  @param Snapshot Immutable input identifier.
   --  @param Result Normalized optional analysis.
   --  @param Status Success or malformed-data failure.
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
      Deadline      : Standard.Ada.Real_Time.Time;
      Cancel        : Model_Runner.Cancellation.Token_Reference;
      Result        : out Model_Runner.Code_Health.Ada.Source_Analysis;
      Status        : out Model_Runner.Errors.Error_Info);

private

   type Instance is limited new Model_Runner.Code_Health.Ada.Source_Analyzer with record
      Source : Problem_Source;
   end record;

end Model_Runner.Code_Health.Ada_LSP_Adapter;
