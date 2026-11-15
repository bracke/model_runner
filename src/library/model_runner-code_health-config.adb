with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Records;

package body Model_Runner.Code_Health.Config is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;
   package R renames Model_Runner.Framework.Records;

   Maximum_Attempts : constant := 1_000;
   Maximum_Feedback : constant := 1024 * 1024;
   Maximum_Deadline : constant := 24 * 60 * 60;

   procedure Refuse
     (Status : out E.Error_Info;
      Name   : String;
      Value  : String;
      Detail : String) is
   begin
      Status := E.Make (E.Framework_Schema_Violation);
      E.Add_Text (Status, "name", Name);
      E.Add_Text (Status, "value", Value);
      E.Add_Text (Status, "detail", Detail);
   end Refuse;

   function Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Word (Value : Boolean) return String is
     (if Value then "true" else "false");

   procedure Natural_Of
     (Name   : String;
      Text   : String;
      Value  : out Natural;
      Status : out E.Error_Info) is
   begin
      Value := Natural'Value (Text);
      Status := E.Success;
   exception
      when Constraint_Error =>
         Value := 0;
         Refuse (Status, Name, Text, "expected a nonnegative integer");
   end Natural_Of;

   procedure Boolean_Of
     (Name   : String;
      Text   : String;
      Value  : out Boolean;
      Status : out E.Error_Info)
   is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Text);
   begin
      if Lower = "true" then
         Value := True;
      elsif Lower = "false" then
         Value := False;
      else
         Value := False;
         Refuse (Status, Name, Text, "expected true or false");
         return;
      end if;
      Status := E.Success;
   end Boolean_Of;

   procedure Set
     (Item   : in out Settings;
      Name   : String;
      Value  : String;
      Status : out E.Error_Info)
   is
      Number : Natural;
      Flag   : Boolean;
   begin
      if Name = "code-health.enabled" then
         Boolean_Of (Name, Value, Flag, Status);
         if E.Is_Ok (Status) then
            Item.Enabled := Flag;
         end if;
      elsif Name = "code-health.on-edit" then
         Boolean_Of (Name, Value, Flag, Status);
         if E.Is_Ok (Status) then
            Item.On_Edit := Flag;
         end if;
      elsif Name = "code-health.fast-profile" then
         Item.Fast_Profile := To_Unbounded_String (Value);
         Status := E.Success;
      elsif Name = "code-health.focused-profile" then
         Item.Focused_Profile := To_Unbounded_String (Value);
         Status := E.Success;
      elsif Name in "code-health.max-stagnant" | "code-health.max-assessments"
                  | "code-health.feedback-limit" | "code-health.fast-deadline"
                  | "code-health.focused-deadline"
      then
         Natural_Of (Name, Value, Number, Status);
         if E.Is_Error (Status) then
            return;
         elsif Name = "code-health.max-stagnant" then
            Item.Maximum_Stagnant := Number;
         elsif Name = "code-health.max-assessments" then
            Item.Maximum_Assessments := Number;
         elsif Name = "code-health.feedback-limit" then
            Item.Feedback_Limit := Number;
         elsif Name = "code-health.fast-deadline" then
            Item.Fast_Deadline := Number;
         else
            Item.Focused_Deadline := Number;
         end if;
      else
         Refuse (Status, Name, Value, "unknown Code Health setting");
      end if;
   end Set;

   procedure Validate
     (Item      : Settings;
      Defined   : Model_Runner.Code_Health.Profiles.Profile_Set;
      Providers : Model_Runner.Code_Health.Providers.Registry;
      Status    : out E.Error_Info) is
   begin
      if Item.Maximum_Stagnant = 0 or else Item.Maximum_Stagnant > Maximum_Attempts then
         Refuse (Status, "code-health.max-stagnant", Image (Item.Maximum_Stagnant), "limit is out of range");
      elsif Item.Maximum_Assessments = 0 or else Item.Maximum_Assessments > Maximum_Attempts then
         Refuse (Status, "code-health.max-assessments", Image (Item.Maximum_Assessments), "limit is out of range");
      elsif Item.Maximum_Stagnant > Item.Maximum_Assessments then
         Refuse (Status, "code-health.max-stagnant", Image (Item.Maximum_Stagnant),
                 "stagnant limit exceeds assessment limit");
      elsif Item.Feedback_Limit < 1024 or else Item.Feedback_Limit > Maximum_Feedback then
         Refuse (Status, "code-health.feedback-limit", Image (Item.Feedback_Limit), "limit is out of range");
      elsif Item.Fast_Deadline = 0 or else Item.Fast_Deadline > Maximum_Deadline then
         Refuse (Status, "code-health.fast-deadline", Image (Item.Fast_Deadline), "deadline is out of range");
      elsif Item.Focused_Deadline = 0 or else Item.Focused_Deadline > Maximum_Deadline then
         Refuse (Status, "code-health.focused-deadline", Image (Item.Focused_Deadline), "deadline is out of range");
      elsif Item.Fast_Deadline > Item.Focused_Deadline then
         Refuse (Status, "code-health.fast-deadline", Image (Item.Fast_Deadline),
                 "fast deadline exceeds focused deadline");
      elsif Item.Enabled
        and then Model_Runner.Code_Health.Profiles.Check_Count (Defined, To_String (Item.Fast_Profile)) = 0
      then
         Refuse (Status, "code-health.fast-profile", To_String (Item.Fast_Profile), "unknown enabled profile");
      elsif Item.Enabled
        and then Model_Runner.Code_Health.Profiles.Check_Count (Defined, To_String (Item.Focused_Profile)) = 0
      then
         Refuse (Status, "code-health.focused-profile", To_String (Item.Focused_Profile),
                 "unknown enabled profile");
      else
         Model_Runner.Code_Health.Profiles.Validate (Defined, Providers, Status);
      end if;
   end Validate;

   function Fingerprint
     (Item     : Settings;
      Defined  : Model_Runner.Code_Health.Profiles.Profile_Set) return String
   is
      Meaning : R.Item := R.Create ("code_health.configuration", 1, "CODE-HEALTH", 1);
   begin
      R.Set (Meaning, "enabled", Word (Item.Enabled));
      R.Set (Meaning, "on_edit", Word (Item.On_Edit));
      R.Set (Meaning, "fast_profile", To_String (Item.Fast_Profile));
      R.Set (Meaning, "focused_profile", To_String (Item.Focused_Profile));
      R.Set (Meaning, "maximum_stagnant", Image (Item.Maximum_Stagnant));
      R.Set (Meaning, "maximum_assessments", Image (Item.Maximum_Assessments));
      R.Set (Meaning, "feedback_limit", Image (Item.Feedback_Limit));
      R.Set (Meaning, "fast_deadline", Image (Item.Fast_Deadline));
      R.Set (Meaning, "focused_deadline", Image (Item.Focused_Deadline));
      R.Set (Meaning, "profiles", Model_Runner.Code_Health.Profiles.Fingerprint (Defined));
      return R.Fingerprint_Of (Meaning);
   end Fingerprint;

end Model_Runner.Code_Health.Config;
