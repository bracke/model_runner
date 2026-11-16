with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Model_Runner.Code_Health.Diagnostics;
with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Immutable comparison points and conservative regression classification.
package Model_Runner.Code_Health.Baselines is

   type Finding_State is
     (New_Finding,
      Existing_Finding,
      Resolved_Finding,
      Changed_Finding,
      Unknown_Finding);

   type Comparison_Context is record
      Snapshot                : Ada.Strings.Unbounded.Unbounded_String;
      Policy_Fingerprint      : Ada.Strings.Unbounded.Unbounded_String;
      Provider_Fingerprint    : Ada.Strings.Unbounded.Unbounded_String;
      Toolchain_Fingerprint   : Ada.Strings.Unbounded.Unbounded_String;
      Environment_Fingerprint : Ada.Strings.Unbounded.Unbounded_String;
      Scope                   : Ada.Strings.Unbounded.Unbounded_String;
      Task_Id                 : Ada.Strings.Unbounded.Unbounded_String;
      Generation              : Natural := 0;
      Workspace               : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Classified_Finding is record
      State    : Finding_State := Unknown_Finding;
      Current  : Diagnostics.Diagnostic;
      Previous : Diagnostics.Diagnostic;
   end record;

   type Classification_List is private;
   type Baseline is private;

   --  @param Context Immutable comparison context.
   --  @param Findings Findings known at the comparison point.
   --  @param Result New in-memory baseline.
   --  @param Status Success or structural failure.
   procedure Create
     (Context     : Comparison_Context;
      Findings    : Diagnostics.Diagnostic_List;
      Result      : out Baseline;
      Status      : out Model_Runner.Errors.Error_Info);

   --  Allocate and stage a new CHB record. A baseline read from the store
   --  cannot be kept again or overwritten through this API.
   --  @param Item Project store.
   --  @param Change Transaction receiving the record.
   --  @param Value Baseline to identify and persist.
   --  @param Status Success or persistence conflict.
   procedure Keep
     (Item     : Model_Runner.Framework.Stores.Store;
      Change   : in out Model_Runner.Framework.Stores.Transaction;
      Value    : in out Baseline;
      Status   : out Model_Runner.Errors.Error_Info);

   --  @param Item Project store.
   --  @param Id Baseline identity.
   --  @param Value Restored baseline.
   --  @param Status Success or read/validation failure.
   procedure Read
     (Item     : Model_Runner.Framework.Stores.Store;
      Id       : String;
      Value    : out Baseline;
      Status   : out Model_Runner.Errors.Error_Info);

   --  @param Item Baseline.
   --  @return Immutable identity.
   function Identifier (Item : Baseline) return String;
   --  @param Item Baseline.
   --  @return Captured context.
   function Context_Of (Item : Baseline) return Comparison_Context;
   --  @param Item Baseline.
   --  @return Captured findings.
   function Findings_Of (Item : Baseline) return Diagnostics.Diagnostic_List;
   --  @param Item Baseline.
   --  @return Task identity.
   function Task_Of (Item : Baseline) return String;
   --  @param Item Baseline.
   --  @return Execution generation.
   function Generation_Of (Item : Baseline) return Natural;
   --  @param Item Baseline.
   --  @return Workspace identity.
   function Workspace_Of (Item : Baseline) return String;

   --  @param Before Immutable baseline.
   --  @param Now Current comparison context.
   --  @return Whether finding comparison is meaningful.
   function Comparable
     (Before : Baseline;
      Now    : Comparison_Context) return Boolean;

   --  @param Before Immutable baseline.
   --  @param Now Current comparison context.
   --  @param Findings Current findings.
   --  @param Result Conservative classifications.
   procedure Compare
     (Before  : Baseline;
      Now     : Comparison_Context;
      Findings : Diagnostics.Diagnostic_List;
      Result  : out Classification_List);

   --  @param Item Classification list.
   --  @return Number of classifications.
   function Length (Item : Classification_List) return Natural;
   --  @param Item Classification list.
   --  @param Index One-based index.
   --  @return Classification.
   function Element (Item : Classification_List; Index : Positive) return Classified_Finding;
   --  @param Item Classification list.
   --  @param State State to count.
   --  @return Matching count.
   function Count (Item : Classification_List; State : Finding_State) return Natural;

   --  @param To Classification list to update.
   --  @param Item Classification to append.
   procedure Append (To : in out Classification_List; Item : Classified_Finding);

   --  Forget all classifications.
   --  @param Item Classification list to clear.
   procedure Clear (Item : in out Classification_List);

   --  New findings at the threshold and worsened corresponding findings
   --  are regressions. Unknown comparisons never silently pass this test.
   --  @param Item Classification list.
   --  @param Threshold Least blocking severity.
   --  @return Whether a blocking or unknown regression remains.
   function Has_Regression
     (Item      : Classification_List;
      Threshold : Diagnostic_Severity) return Boolean;

private

   package Classification_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Classified_Finding);

   type Classification_List is record
      Items : Classification_Vectors.Vector;
   end record;

   type Baseline is record
      Id         : Ada.Strings.Unbounded.Unbounded_String;
      Context    : Comparison_Context;
      Findings   : Diagnostics.Diagnostic_List;
   end record;

end Model_Runner.Code_Health.Baselines;
