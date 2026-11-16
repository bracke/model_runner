with Ada.Strings.Unbounded;

with Model_Runner.Code_Health.Diagnostics;

--  Bounded, deterministic rendering of trusted assessment state and
--  explicitly untrusted provider diagnostic data.
package Model_Runner.Code_Health.Feedback is

   subtype Feedback_Bytes is Positive range 256 .. 1024 * 1024;

   type Render_Limits is record
      Diagnostics_Shown : Natural := 20;
      Total_Bytes       : Feedback_Bytes := 8 * 1024;
      Message_Bytes     : Positive := 1024;
      Remediation_Bytes : Positive := 1024;
   end record;

   Default_Limits : constant Render_Limits :=
     (Diagnostics_Shown => 20,
      Total_Bytes       => 8 * 1024,
      Message_Bytes     => 1024,
      Remediation_Bytes => 1024);

   type Assessment is record
      Identifier    : Ada.Strings.Unbounded.Unbounded_String;
      Level         : Check_Level := Fast;
      State         : Health_State := Not_Started;
      Snapshot      : Ada.Strings.Unbounded.Unbounded_String;
      Files_Analyzed : Natural := 0;
      Checks_Passed : Natural := 0;
      Checks_Failed : Natural := 0;
      New_Errors    : Natural := 0;
      New_Warnings  : Natural := 0;
      Existing      : Natural := 0;
      Resolved      : Natural := 0;
      Unknown       : Natural := 0;
      Findings      : Diagnostics.Diagnostic_List;
      Completion    : Gate_Decision := Allow_Completion;
      Next_Action   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  @param Item Assessment to render.
   --  @param Limits Validated output bounds.
   --  @return Structured code-health/1 JSON.
   function Render_JSON
     (Item   : Assessment;
      Limits : Render_Limits := Default_Limits) return String;

   --  @param Item Assessment to render.
   --  @param Limits Validated output bounds.
   --  @return Compact trusted model-facing text.
   function Render_Model
     (Item   : Assessment;
      Limits : Render_Limits := Default_Limits) return String;

end Model_Runner.Code_Health.Feedback;
