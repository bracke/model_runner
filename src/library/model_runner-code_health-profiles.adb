with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Records;

package body Model_Runner.Code_Health.Profiles is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;
   package P renames Model_Runner.Code_Health.Providers;
   package R renames Model_Runner.Framework.Records;

   Maximum_Timeout : constant := 24 * 60 * 60;
   Maximum_Output  : constant := 16 * 1024 * 1024;

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

   function Word (Value : Check_Level) return String is
     (Ada.Characters.Handling.To_Lower (Check_Level'Image (Value)));

   function Word (Value : Diagnostic_Severity) return String is
     (Ada.Characters.Handling.To_Lower (Diagnostic_Severity'Image (Value)));

   function Word (Value : Scope_Kind) return String is
     (Ada.Characters.Handling.To_Lower (Scope_Kind'Image (Value)));

   function Word (Value : Cache_Kind) return String is
     (Ada.Characters.Handling.To_Lower (Cache_Kind'Image (Value)));

   function Find_Profile
     (From : Profile_Set;
      Name : String) return Natural is
   begin
      for Index in 1 .. Natural (From.Items.Length) loop
         if To_String (From.Items.Element (Index).Name) = Name then
            return Index;
         end if;
      end loop;
      return 0;
   end Find_Profile;

   procedure Add
     (To      : in out Profile_Set;
      Profile : String;
      Check   : Check_Definition)
   is
      Index : constant Natural := Find_Profile (To, Profile);
   begin
      if Index = 0 then
         declare
            Item : Named_Profile;
         begin
            Item.Name := To_Unbounded_String (Profile);
            Item.Checks.Append (Check);
            To.Items.Append (Item);
         end;
      else
         To.Items.Reference (Index).Checks.Append (Check);
      end if;
   end Add;

   function Profile_Count (From : Profile_Set) return Natural is
     (Natural (From.Items.Length));

   function Profile_Name
     (From  : Profile_Set;
      Index : Positive) return String is
     (To_String (From.Items.Element (Index).Name));

   function Check_Count
     (From    : Profile_Set;
      Profile : String) return Natural
   is
      Index : constant Natural := Find_Profile (From, Profile);
   begin
      return (if Index = 0 then 0
              else Natural (From.Items.Element (Index).Checks.Length));
   end Check_Count;

   function Check_At
     (From    : Profile_Set;
      Profile : String;
      Index   : Positive) return Check_Definition
   is
      Position : constant Natural := Find_Profile (From, Profile);
   begin
      return From.Items.Element (Position).Checks.Element (Index);
   end Check_At;

   procedure Validate
     (Item      : Profile_Set;
      Providers : P.Registry;
      Status    : out E.Error_Info)
   is
   begin
      for Profile_Index in 1 .. Natural (Item.Items.Length) loop
         declare
            Profile : constant Named_Profile := Item.Items.Element (Profile_Index);
            Name    : constant String := To_String (Profile.Name);
            Count   : constant Natural := Natural (Profile.Checks.Length);
            type Visit_State is (Unseen, Visiting, Seen);
            type Visit_Array is array (Natural range <>) of Visit_State;
            Visits : Visit_Array (1 .. Count) := [others => Unseen];

            function Find_Check (Identifier : String) return Natural is
            begin
               for Index in 1 .. Count loop
                  if To_String (Profile.Checks.Element (Index).Identifier) = Identifier then
                     return Index;
                  end if;
               end loop;
               return 0;
            end Find_Check;

            function Has_Cycle (Index : Positive) return Boolean is
               Check : constant Check_Definition := Profile.Checks.Element (Index);
            begin
               if Visits (Index) = Visiting then
                  return True;
               elsif Visits (Index) = Seen then
                  return False;
               end if;
               Visits (Index) := Visiting;
               for Dependency of Check.Dependencies loop
                  declare
                     Target : constant Natural := Find_Check (Dependency);
                  begin
                     if Target > 0 and then Has_Cycle (Target) then
                        return True;
                     end if;
                  end;
               end loop;
               Visits (Index) := Seen;
               return False;
            end Has_Cycle;
         begin
            if not P.Valid_Identifier (Name) then
               Refuse (Status, "profile", Name, "invalid profile identifier");
               return;
            elsif Count = 0 then
               Refuse (Status, "profile", Name, "profile has no checks");
               return;
            end if;

            for Earlier in 1 .. Profile_Index - 1 loop
               if To_String (Item.Items.Element (Earlier).Name) = Name then
                  Refuse (Status, "profile", Name, "duplicate profile identifier");
                  return;
               end if;
            end loop;

            for Check_Index in 1 .. Count loop
               declare
                  Check    : constant Check_Definition := Profile.Checks.Element (Check_Index);
                  Check_Id : constant String := To_String (Check.Identifier);
                  Provider : constant String := To_String (Check.Provider);
               begin
                  if not P.Valid_Identifier (Check_Id) then
                     Refuse (Status, "check", Check_Id, "invalid check identifier");
                     return;
                  elsif not P.Valid_Identifier (Provider) then
                     Refuse (Status, "provider", Provider, "invalid provider identifier");
                     return;
                  elsif Check.Required and then not P.Contains (Providers, Provider) then
                     Refuse (Status, "provider", Provider, "mandatory provider is not registered");
                     return;
                  elsif Check.Timeout_Seconds = 0 or else Check.Timeout_Seconds > Maximum_Timeout then
                     Refuse (Status, "timeout", Image (Check.Timeout_Seconds), "check timeout is out of range");
                     return;
                  elsif Check.Output_Limit = 0 or else Check.Output_Limit > Maximum_Output then
                     Refuse (Status, "output_limit", Image (Check.Output_Limit), "check output limit is out of range");
                     return;
                  end if;

                  for Earlier in 1 .. Check_Index - 1 loop
                     if To_String (Profile.Checks.Element (Earlier).Identifier) = Check_Id then
                        Refuse (Status, "check", Check_Id, "duplicate check identifier");
                        return;
                     end if;
                  end loop;

                  for Dependency of Check.Dependencies loop
                     if Find_Check (Dependency) = 0 then
                        Refuse (Status, "dependency", Dependency, "unknown check dependency");
                        return;
                     end if;
                  end loop;
               end;
            end loop;

            for Check_Index in 1 .. Count loop
               if Has_Cycle (Check_Index) then
                  Status := E.Make (E.Framework_Dependency_Cycle);
                  E.Add_Text (Status, "name", Name);
                  return;
               end if;
            end loop;
         end;
      end loop;
      Status := E.Success;
   end Validate;

   function Fingerprint (Item : Profile_Set) return String is
      Meaning : R.Item := R.Create ("code_health.profiles", 1, "CODE-HEALTH", 1);

      function Profile_Less (Left, Right : Named_Profile) return Boolean is
        (To_String (Left.Name) < To_String (Right.Name));
      package Profile_Sorting is new Profile_Lists.Generic_Sorting (Profile_Less);

      function Check_Less (Left, Right : Check_Definition) return Boolean is
        (To_String (Left.Identifier) < To_String (Right.Identifier));
      package Check_Sorting is new Check_Lists.Generic_Sorting (Check_Less);

      package String_Sorting is new String_Lists.Generic_Sorting;

      Sorted_Profiles : Profile_Lists.Vector := Item.Items;
   begin
      Profile_Sorting.Sort (Sorted_Profiles);
      for Profile_Index in 1 .. Natural (Sorted_Profiles.Length) loop
         declare
            Profile : Named_Profile := Sorted_Profiles.Element (Profile_Index);
            Prefix  : constant String := "profile." & R.Numbered (Profile_Index, Natural (Sorted_Profiles.Length));
         begin
            Check_Sorting.Sort (Profile.Checks);
            R.Set (Meaning, Prefix & ".name", To_String (Profile.Name));
            for Check_Index in 1 .. Natural (Profile.Checks.Length) loop
               declare
                  Check        : constant Check_Definition := Profile.Checks.Element (Check_Index);
                  Check_Prefix : constant String := Prefix & ".check."
                    & R.Numbered (Check_Index, Natural (Profile.Checks.Length));
                  Dependencies : String_Lists.Vector := Check.Dependencies;
                  Tools        : String_Lists.Vector := Check.Tool_Requirements;
               begin
                  String_Sorting.Sort (Dependencies);
                  String_Sorting.Sort (Tools);
                  R.Set (Meaning, Check_Prefix & ".id", To_String (Check.Identifier));
                  R.Set (Meaning, Check_Prefix & ".provider", To_String (Check.Provider));
                  R.Set (Meaning, Check_Prefix & ".level", Word (Check.Level));
                  R.Set (Meaning, Check_Prefix & ".required", Word (Check.Required));
                  R.Set (Meaning, Check_Prefix & ".block_on", Word (Check.Block_On));
                  R.Set (Meaning, Check_Prefix & ".scope", Word (Check.Scope));
                  R.Set (Meaning, Check_Prefix & ".timeout", Image (Check.Timeout_Seconds));
                  R.Set (Meaning, Check_Prefix & ".cache", Word (Check.Cache));
                  R.Set (Meaning, Check_Prefix & ".output_limit", Image (Check.Output_Limit));
                  for Index in 1 .. Natural (Dependencies.Length) loop
                     R.Set (Meaning, Check_Prefix & ".dependency."
                            & R.Numbered (Index, Natural (Dependencies.Length)), Dependencies.Element (Index));
                  end loop;
                  for Index in 1 .. Natural (Tools.Length) loop
                     R.Set (Meaning, Check_Prefix & ".tool."
                            & R.Numbered (Index, Natural (Tools.Length)), Tools.Element (Index));
                  end loop;
               end;
            end loop;
         end;
      end loop;
      return R.Fingerprint_Of (Meaning);
   end Fingerprint;

   procedure Severity_Of
     (Text   : String;
      Value  : out Diagnostic_Severity;
      Status : out E.Error_Info)
   is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Text);
   begin
      if Lower = "information" then
         Value := Information;
      elsif Lower = "warning" then
         Value := Warning;
      elsif Lower = "error" then
         Value := Error;
      elsif Lower = "critical" then
         Value := Critical;
      else
         Value := Error;
         Refuse (Status, "severity", Text, "unknown diagnostic severity");
         return;
      end if;
      Status := E.Success;
   end Severity_Of;

end Model_Runner.Code_Health.Profiles;
