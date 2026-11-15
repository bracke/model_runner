with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Model_Runner.Code_Health.Providers;
with Model_Runner.Errors;

--  Declarative check profiles and their configuration-time validation.
package Model_Runner.Code_Health.Profiles is

   type Scope_Kind is
     (Changed_Files,
      Dependency_Scope,
      Whole_Project);

   type Cache_Kind is
     (No_Cache,
      Exact_Inputs);

   type Check_Definition is record
      Identifier        : Ada.Strings.Unbounded.Unbounded_String;
      Provider          : Ada.Strings.Unbounded.Unbounded_String;
      Level             : Check_Level := Fast;
      Required          : Boolean := True;
      Block_On          : Diagnostic_Severity := Error;
      Scope             : Scope_Kind := Changed_Files;
      Timeout_Seconds   : Natural := 10;
      Dependencies      : String_Lists.Vector;
      Cache             : Cache_Kind := Exact_Inputs;
      Tool_Requirements : String_Lists.Vector;
      Output_Limit      : Natural := 8 * 1024;
   end record;

   type Profile_Set is private;

   procedure Add
     (To      : in out Profile_Set;
      Profile : String;
      Check   : Check_Definition);

   function Profile_Count (From : Profile_Set) return Natural;

   function Profile_Name
     (From  : Profile_Set;
      Index : Positive) return String;

   function Check_Count
     (From    : Profile_Set;
      Profile : String) return Natural;

   function Check_At
     (From    : Profile_Set;
      Profile : String;
      Index   : Positive) return Check_Definition;

   --  Validate identifiers, bounds, mandatory providers, dependencies and
   --  dependency acyclicity.  Optional checks may name an unavailable
   --  provider; they remain explicitly unavailable when selected later.
   procedure Validate
     (Item      : Profile_Set;
      Providers : Model_Runner.Code_Health.Providers.Registry;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Sixteen hexadecimal digits covering profile policy semantics.  Input
   --  insertion order and dependency-list order do not change the result.
   function Fingerprint (Item : Profile_Set) return String;

   procedure Severity_Of
     (Text   : String;
      Value  : out Diagnostic_Severity;
      Status : out Model_Runner.Errors.Error_Info);

private

   package Check_Lists is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Check_Definition);

   type Named_Profile is record
      Name   : Ada.Strings.Unbounded.Unbounded_String;
      Checks : Check_Lists.Vector;
   end record;

   package Profile_Lists is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Named_Profile);

   type Profile_Set is record
      Items : Profile_Lists.Vector;
   end record;

end Model_Runner.Code_Health.Profiles;
