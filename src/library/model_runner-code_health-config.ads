with Ada.Strings.Unbounded;

with Model_Runner.Code_Health.Profiles;
with Model_Runner.Code_Health.Providers;
with Model_Runner.Errors;

--  Validated interactive Code Health settings.  Project-task policy is
--  resolved by the framework and may only strengthen these preferences.
package Model_Runner.Code_Health.Config is

   type Settings is record
      Enabled          : Boolean := False;
      On_Edit          : Boolean := True;
      Fast_Profile     : Ada.Strings.Unbounded.Unbounded_String;
      Focused_Profile  : Ada.Strings.Unbounded.Unbounded_String;
      Maximum_Stagnant : Natural := 3;
      Maximum_Assessments : Natural := 12;
      Feedback_Limit   : Natural := 8 * 1024;
      Fast_Deadline    : Natural := 10;
      Focused_Deadline : Natural := 120;
   end record;

   Defaults : constant Settings;

   --  Apply one key from the global settings file.  Unknown code-health
   --  keys are refused, as are malformed booleans and numeric values.
   procedure Set
     (Item   : in out Settings;
      Name   : String;
      Value  : String;
      Status : out Model_Runner.Errors.Error_Info);

   procedure Validate
     (Item      : Settings;
      Defined   : Model_Runner.Code_Health.Profiles.Profile_Set;
      Providers : Model_Runner.Code_Health.Providers.Registry;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Sixteen hexadecimal digits covering settings and profile semantics.
   function Fingerprint
     (Item     : Settings;
      Defined  : Model_Runner.Code_Health.Profiles.Profile_Set) return String;

private

   Defaults : constant Settings :=
     (Enabled             => False,
      On_Edit             => True,
      Fast_Profile        => Ada.Strings.Unbounded.To_Unbounded_String ("ada-fast"),
      Focused_Profile     => Ada.Strings.Unbounded.To_Unbounded_String ("ada-focused"),
      Maximum_Stagnant    => 3,
      Maximum_Assessments => 12,
      Feedback_Limit      => 8 * 1024,
      Fast_Deadline       => 10,
      Focused_Deadline    => 120);

end Model_Runner.Code_Health.Config;
