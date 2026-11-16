with Ada.Directories;

with Model_Runner.Code_Health.Baselines;
with Model_Runner.Code_Health.Diagnostics;
with Model_Runner.Code_Health.Evidence;
with Model_Runner.Code_Health.Profiles;
with Model_Runner.Code_Health.Providers;
with Model_Runner.Framework;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Verification;

package body Model_Runner.Code_Health.Lifecycle is

   use Ada.Strings.Unbounded;

   package B renames Model_Runner.Code_Health.Baselines;
   package C renames Model_Runner.Framework.Configurations;
   package D renames Model_Runner.Code_Health.Diagnostics;
   package E renames Model_Runner.Errors;
   package H_Evidence renames Model_Runner.Code_Health.Evidence;
   package P renames Model_Runner.Code_Health.Providers;
   package R renames Model_Runner.Framework.Records;
   package Repo renames Model_Runner.Framework.Repository;
   package S renames Model_Runner.Framework.Stores;
   package V renames Model_Runner.Framework.Verification;

   use type B.Finding_State;
   use type P.Check_Status;
   use type V.Applicability;

   function Failed (Why : String; Evidence : String := "") return Gate_Report is
     (Passed   => False,
      Evidence => To_Unbounded_String (Evidence),
      Reason   => To_Unbounded_String (Why));

   function Number (Text : String; Good : out Boolean) return Natural is
      Result : Natural := 0;
   begin
      Good := Text /= "";
      for Letter of Text loop
         if Letter not in '0' .. '9' or else Result > (Natural'Last - 9) / 10 then
            Good := False;
            return 0;
         end if;
         Result := Result * 10 + Character'Pos (Letter) - Character'Pos ('0');
      end loop;
      return Result;
   end Number;

   procedure Record_Full_Verification
     (Item                  : S.Store;
      Change                : in out S.Transaction;
      Task_Id               : String;
      Agent_Id              : String;
      Invocation_Id         : String;
      Verification_Evidence : String;
      Verification_Passed   : Boolean;
      Assessment_Id         : out Unbounded_String;
      Status                : out E.Error_Info)
   is
      Settings   : R.Item;
      Runtime    : R.Item;
      Formal     : R.Item;
      Staged     : Boolean;
      Good       : Boolean;
      Generation : Natural;
   begin
      Assessment_Id := Null_Unbounded_String;
      C.Read (Item, Settings, Status);
      if E.Is_Error (Status) then
         return;
      elsif R.Get (Settings, "scalar.code_health.enabled") /= "true" then
         Status := E.Success;
         return;
      elsif R.Get (Settings, "profile.code_health.full") = "" then
         Status := E.Make (E.Framework_Schema_Violation);
         E.Add_Text (Status, "name", "profile.code_health.full");
         E.Add_Text (Status, "detail", "an enabled project has no full Code Health profile");
         return;
      end if;
      S.Read (Item, Model_Runner.Framework.Tasks_Area, Task_Id & ".state", Runtime, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Generation := Number (R.Get (Runtime, "generation"), Good);
      if not Good then
         Status := E.Make (E.Framework_Schema_Violation);
         E.Add_Text (Status, "name", Task_Id & ".generation");
         return;
      end if;
      S.Pending
        (Change, Model_Runner.Framework.Verification_Area,
         Verification_Evidence, Formal, Staged);
      if not Staged then
         S.Read
           (Item, Model_Runner.Framework.Verification_Area,
            Verification_Evidence, Formal, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end if;

      declare
         Snapshot : constant String :=
           Repo.Graph_Fingerprint (Repo.Now (Item));
         Context  : constant H_Evidence.Assessment_Context :=
           (Project                   => To_Unbounded_String
              (Ada.Directories.Containing_Directory (S.Root (Item))),
            Task_Id                   => To_Unbounded_String (Task_Id),
            Generation                => Generation,
            Agent_Id                  => To_Unbounded_String (Agent_Id),
            Invocation_Id             => To_Unbounded_String (Invocation_Id),
            Workspace                 => Null_Unbounded_String,
            Snapshot                  => To_Unbounded_String (Snapshot),
            Configuration_Fingerprint => To_Unbounded_String
              (C.Code_Health_Fingerprint (Settings)),
            Toolchain_Fingerprint     => To_Unbounded_String
              ("framework-verification/" & Verification_Evidence),
            Environment_Fingerprint   => To_Unbounded_String
              ((if R.Get (Formal, "environment_fingerprint") = ""
                then "framework-environment"
                else R.Get (Formal, "environment_fingerprint"))),
            Profile                   => To_Unbounded_String
              (R.Get (Settings, "profile.code_health.full")));
         Provider_Result : P.Analysis_Result;
         Results         : H_Evidence.Analysis_Result_Lists.Vector;
         Classifications : B.Classification_List;
         Assessment      : H_Evidence.Assessment;
      begin
         Provider_Result.Provider_Id := To_Unbounded_String ("framework-verification");
         Provider_Result.Provider_Version := To_Unbounded_String ("1.0.0");
         Provider_Result.Input_Fingerprint := Context.Snapshot;
         Provider_Result.Configuration_Fingerprint := Context.Configuration_Fingerprint;
         Provider_Result.Toolchain_Fingerprint := Context.Toolchain_Fingerprint;
         Provider_Result.Environment_Fingerprint := Context.Environment_Fingerprint;
         Provider_Result.Evidence.Append (Verification_Evidence);
         Provider_Result.Checks.Append
           (P.Check_Result'
              (Identifier => To_Unbounded_String
                 ("verification:" & R.Get (Formal, "profile")),
               Status     => (if Verification_Passed then P.Check_Passed else P.Check_Findings),
               Required   => True,
               Detail     => To_Unbounded_String
                 (if Verification_Passed then "" else Verification_Evidence & " did not pass"),
               Evidence   => To_Unbounded_String (Verification_Evidence)));
         Results.Append (Provider_Result);
         H_Evidence.Create
           (Context, Full, (if Verification_Passed then Passed else Blocked),
            Results, Classifications, "", "", Assessment, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         H_Evidence.Keep (Item, Change, Assessment, Status);
         if E.Is_Ok (Status) then
            Assessment_Id := To_Unbounded_String (H_Evidence.Identifier (Assessment));
         end if;
      end;
   end Record_Full_Verification;

   function Judge (Item : S.Store; Task_Id : String) return Gate_Report is
      Settings   : R.Item;
      State      : R.Item;
      Status     : E.Error_Info;
      Good       : Boolean;
      Generation : Natural;
      Candidate  : Unbounded_String;
      Profile    : Unbounded_String;
   begin
      C.Read (Item, Settings, Status);
      if E.Is_Error (Status) then
         return Failed ("the project configuration cannot be read");
      elsif R.Get (Settings, "scalar.code_health.enabled") /= "true" then
         return Failed ("Code Health is not enabled for this task");
      end if;
      Profile := To_Unbounded_String (R.Get (Settings, "profile.code_health.full"));
      if Profile = Null_Unbounded_String then
         return Failed ("no full Code Health profile is configured");
      end if;

      S.Read (Item, Model_Runner.Framework.Tasks_Area, Task_Id & ".state", State, Status);
      if E.Is_Error (Status) then
         return Failed ("the task state cannot be read");
      end if;
      Generation := Number (R.Get (State, "generation"), Good);
      if not Good then
         return Failed ("the task has no valid execution generation");
      end if;

      --  Select before judging applicability or outcome. A newer failed or
      --  unavailable mandatory assessment must not expose an older pass.
      for Id of S.Names (Item, Model_Runner.Framework.Verification_Area) loop
         declare
            Held : R.Item;
            Read : E.Error_Info;
         begin
            S.Read (Item, Model_Runner.Framework.Verification_Area, Id, Held, Read);
            if E.Is_Ok (Read)
              and then R.Get (Held, "code_health.kind") = "assessment"
              and then R.Get (Held, "task") = Task_Id
              and then R.Get (Held, "code_health.generation") = R.Get (State, "generation")
              and then R.Get (Held, "code_health.level") = "full"
              and then R.Get (Held, "profile") = To_String (Profile)
              and then Model_Runner.Framework.Later (Id, To_String (Candidate))
            then
               Candidate := To_Unbounded_String (Id);
            end if;
         end;
      end loop;
      if Candidate = Null_Unbounded_String then
         return Failed
           ("profile " & To_String (Profile)
            & " has no full assessment for this task generation");
      end if;

      declare
         Assessment : H_Evidence.Assessment;
         Current    : H_Evidence.Assessment_Context;
         Stands     : V.Applicability_Report;
         Checks     : Natural := 0;
         Required   : Natural := 0;
         Findings   : Natural := 0;
         Threshold  : Diagnostic_Severity := Error;
      begin
         H_Evidence.Read (Item, To_String (Candidate), Assessment, Status);
         if E.Is_Error (Status) then
            return Failed (To_String (Candidate) & " cannot be used", To_String (Candidate));
         end if;
         Current := H_Evidence.Context_Of (Assessment);
         Current.Project := To_Unbounded_String
           (Ada.Directories.Containing_Directory (S.Root (Item)));
         Current.Task_Id := To_Unbounded_String (Task_Id);
         Current.Generation := Generation;
         Current.Workspace := Null_Unbounded_String;
         Current.Snapshot := To_Unbounded_String
           (Repo.Graph_Fingerprint (Repo.Now (Item)));
         Current.Configuration_Fingerprint := To_Unbounded_String
           (C.Code_Health_Fingerprint (Settings));
         Current.Profile := Profile;
         Stands := H_Evidence.Applicable (Item, To_String (Candidate), Current);
         if Stands.Kind /= V.Current then
            return Failed
              ((if Stands.Reasons.Is_Empty then To_String (Candidate) & " is not current"
                else Stands.Reasons.First_Element),
               To_String (Candidate));
         end if;

         if H_Evidence.Level_Of (Assessment) /= Full then
            return Failed (To_String (Candidate) & " is not a full assessment", To_String (Candidate));
         elsif H_Evidence.State_Of (Assessment) not in Passed | Findings_Present then
            return Failed
              (To_String (Candidate) & " ended "
               & Health_State'Image (H_Evidence.State_Of (Assessment)),
               To_String (Candidate));
         end if;
         for Result of H_Evidence.Results_Of (Assessment) loop
            Findings := Findings + D.Length (Result.Diagnostics);
            for Check of Result.Checks loop
               Checks := Checks + 1;
               if Check.Required then
                  Required := Required + 1;
                  if Check.Status not in P.Check_Passed | P.Check_Findings then
                     return Failed
                       ("required check " & To_String (Check.Identifier) & " ended "
                        & P.Check_Status'Image (Check.Status),
                        To_String (Candidate));
                  end if;
               end if;
            end loop;
         end loop;
         if Checks = 0 or else Required = 0 then
            return Failed
              (To_String (Candidate) & " contains no mandatory check result",
               To_String (Candidate));
         end if;

         if R.Get (Settings, "scalar.code_health.block_on") /= "" then
            Model_Runner.Code_Health.Profiles.Severity_Of
              (R.Get (Settings, "scalar.code_health.block_on"), Threshold, Status);
            if E.Is_Error (Status) then
               return Failed ("the Code Health blocking severity is invalid");
            end if;
         end if;
         if Findings > 0 and then B.Length (H_Evidence.Classifications_Of (Assessment)) = 0 then
            return Failed
              (To_String (Candidate) & " has unclassified findings",
               To_String (Candidate));
         end if;
         for Index in 1 .. B.Length (H_Evidence.Classifications_Of (Assessment)) loop
            declare
               Finding : constant B.Classified_Finding :=
                 B.Element (H_Evidence.Classifications_Of (Assessment), Index);
            begin
               if Finding.State = B.Unknown_Finding then
                  return Failed
                    (To_String (Candidate) & " has a finding that cannot be compared",
                     To_String (Candidate));
               elsif Finding.State in B.New_Finding | B.Changed_Finding
                 and then Finding.Current.Severity >= Threshold
               then
                  return Failed
                    (To_String (Candidate) & " has a blocking regression",
                     To_String (Candidate));
               end if;
            end;
         end loop;
         return
           (Passed   => True,
            Evidence => Candidate,
            Reason   => Null_Unbounded_String);
      end;
   end Judge;

end Model_Runner.Code_Health.Lifecycle;
