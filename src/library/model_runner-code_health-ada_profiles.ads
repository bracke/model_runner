with Model_Runner.Code_Health.Profiles;
with Model_Runner.Code_Health.Providers;
with Model_Runner.Errors;

--  Built-in change-oriented Ada profiles. The full completion profile remains
--  owned by Model_Runner.Framework.Verification.
package Model_Runner.Code_Health.Ada_Profiles is

   --  @param To Profile set receiving ada-fast and ada-focused.
   procedure Add_Defaults
     (To : in out Model_Runner.Code_Health.Profiles.Profile_Set);

   --  Resolve project-policy check names to native provider checks.  The
   --  value may use the framework set representation (line or comma
   --  separated).  Several source-rule groups intentionally map to the
   --  single shared ada_quality execution.
   --  @param Names Configured check names.
   --  @param Level Assessment level.
   --  @param Result Native requested checks.
   --  @param Status Success or unknown/inapplicable check name.
   procedure Resolve
     (Names  : String;
      Level  : Check_Level;
      Result : out Model_Runner.Code_Health.Providers.Requested_Check_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info);

end Model_Runner.Code_Health.Ada_Profiles;
