with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Model_Runner.Errors;

--  Provider-independent findings.  Providers retain their native identity
--  here; presentation and blocking policy are applied later by the harness.
package Model_Runner.Code_Health.Diagnostics is

   type Source_Location is record
      Path   : Ada.Strings.Unbounded.Unbounded_String;
      Line   : Natural := 0;
      Column : Natural := 0;
   end record;

   package Location_Lists is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Source_Location);

   type Diagnostic is record
      Provider        : Ada.Strings.Unbounded.Unbounded_String;
      Rule_Id         : Ada.Strings.Unbounded.Unbounded_String;
      Severity        : Diagnostic_Severity := Information;
      Path            : Ada.Strings.Unbounded.Unbounded_String;
      Line            : Natural := 0;
      Column          : Natural := 0;
      Symbol          : Ada.Strings.Unbounded.Unbounded_String;
      Message         : Ada.Strings.Unbounded.Unbounded_String;
      Explanation     : Ada.Strings.Unbounded.Unbounded_String;
      Remediation     : Ada.Strings.Unbounded.Unbounded_String;
      Fingerprint     : Ada.Strings.Unbounded.Unbounded_String;
      Evidence_Id     : Ada.Strings.Unbounded.Unbounded_String;
      Native_Code     : Ada.Strings.Unbounded.Unbounded_String;
      Snapshot        : Ada.Strings.Unbounded.Unbounded_String;
      Related         : Location_Lists.Vector;
      Provenance      : String_Lists.Vector;
   end record;

   type Diagnostic_List is private;

   --  Validate provider data, normalize its path and compute the harness's
   --  stable fingerprint. Invalid data never enters evidence or feedback.
   procedure Prepare
     (Item         : in out Diagnostic;
      Status       : out Model_Runner.Errors.Error_Info;
      Project_Root : String := "");

   procedure Append_Validated
     (To           : in out Diagnostic_List;
      Item         : Diagnostic;
      Status       : out Model_Runner.Errors.Error_Info;
      Project_Root : String := "");

   function Length (From : Diagnostic_List) return Natural;

   function Element
     (From  : Diagnostic_List;
      Index : Positive) return Diagnostic;

   function Fingerprint_Of (Item : Diagnostic) return String;

   function Blocks
     (Item      : Diagnostic;
      Threshold : Diagnostic_Severity) return Boolean;

   function Count
     (From     : Diagnostic_List;
      Severity : Diagnostic_Severity) return Natural;

   procedure Sort (Item : in out Diagnostic_List);

   --  Merge only matching semantic identities and retain every contributor.
   procedure Deduplicate (Item : in out Diagnostic_List);

private

   package Diagnostic_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Diagnostic);

   type Diagnostic_List is record
      Items : Diagnostic_Vectors.Vector;
   end record;

end Model_Runner.Code_Health.Diagnostics;
