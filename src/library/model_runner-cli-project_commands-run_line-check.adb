separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Check (Store : in out S.Store) is
   Config   : R.Item;
   Change   : S.Transaction;
begin
   --  A requirement: the tasks serving it verified again, the
   --  requirement itself where the project has a profile for that,
   --  and where it stands then -- with what it still lacks.
   if Argument (1)'Length > 4
     and then Argument (1) (Argument (1)'First .. Argument (1)'First + 3) = "REQ-"
   then
      declare
         package Vf renames Model_Runner.Framework.Verification;
         package Tk renames Model_Runner.Framework.Tasks;
         Requirement : constant String := Argument (1);
         Held        : Model_Runner.Framework.Intent.Entity;
         Got         : E.Error_Info;
         Evidence    : Unbounded_String;
         Passed      : Boolean;
         Changed     : Names.Vector;
         Failing     : Names.Vector;
      begin
         Model_Runner.Framework.Intent.Read
           (Store, Model_Runner.Framework.Intent.Requirement, Requirement, Held, Got);
         if E.Is_Error (Got) then
            Pres.Report (Screen, Got);
            return;
         end if;
         --  Retired: nothing to verify, and its replacement named.
         if To_String (Held.State) in "obsolete" | "rejected" | "superseded" then
            Got := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Got, "name", "the requirement to check");
            E.Add_Text (Got, "value", Requirement);
            E.Add_Text (Got, "detail", Requirement & " is " & To_String (Held.State)
                        & (if Held.Superseded_By /= Null_Unbounded_String
                           then ", replaced by " & To_String (Held.Superseded_By) & ": check "
                                & To_String (Held.Superseded_By) & " verifies that one"
                           else ", and what is retired is not verified"));
            Pres.Report (Screen, Got);
            return;
         end if;
         for Id of Tk.List (Store) loop
            declare
               Defined : R.Item;
            begin
               Tk.Definition (Store, Id, Defined, Got);
               if E.Is_Ok (Got)
                 and then Model_Runner.Framework.Lines_Of
                            (R.Get (Defined, "requirements")).Contains (Requirement)
                 and then Tk.State_Of (Store, Id) = Tk.Complete
                 and then Vf.Profile_Of (Store, Id) /= ""
               then
                  Vf.Run_Profile (Store, Change, Vf.Profile_Of (Store, Id), Id, Evidence,
                                  Passed, Got);
                  if E.Is_Ok (Got) then
                     S.Commit (Store, Change, Got);
                     Field (Id, To_String (Evidence) & (if Passed then " passed" else " failed"));
                     if not Passed then
                        Failing.Append (To_String (Evidence));
                     end if;
                  end if;
               end if;
            end;
         end loop;
         Vf.Verify_Requirement (Store, Change, Requirement, Evidence, Passed, Got);
         if E.Is_Ok (Got) then
            S.Commit (Store, Change, Got);
            Field (Requirement, To_String (Evidence) & (if Passed then " passed" else " failed"));
            if not Passed then
               Failing.Append (To_String (Evidence));
            end if;
         end if;
         Change := S.No_Changes;
         Vf.Reevaluate_Requirements (Store, Change, Changed, Got);
         S.Commit (Store, Change, Got);
         Model_Runner.Framework.Intent.Read
           (Store, Model_Runner.Framework.Intent.Requirement, Requirement, Held, Got);
         Field ("state", To_String (Held.State));
         --  The others the checks moved, each named as what it is: a
         --  side effect of the same evidence, not what was asked.
         for Other of Changed loop
            if Other /= Requirement then
               Pres.Put_Note
                 (Screen, "cli.work.requirement_also",
                  [Loc.Named ("name", Other),
                   Loc.Named ("value", Nt.State_Of (Store, Nt.Requirement, Other))]);
            end if;
         end loop;
         --  Its checks passed and it is not verified: said as what it
         --  is -- not a check that failed -- with what it waits for,
         --  and the command ends without success all the same.
         if To_String (Held.State) /= "verified" and then Failing.Is_Empty then
            Pres.Put_Message
              (Screen, "cli.check.passed_not_verified",
               [Loc.Named ("name", Requirement),
                Loc.Named ("detail", Vf.Why_Not_Verified (Store, Requirement))]);
            Last_Status := E.Exit_Status (E.Make (E.Framework_Verification_Failed));
         elsif To_String (Held.State) /= "verified" then
            Field ("not verified", Vf.Why_Not_Verified (Store, Requirement));
         end if;

         --  Checks that did not pass: a failure, with why.
         for Evidence_Id of Failing loop
            declare
               Failed : E.Error_Info := E.Make (E.Framework_Verification_Failed);
               Why    : Unbounded_String;
            begin
               for Line of Vf.Why_Failed (Store, Evidence_Id) loop
                  Append (Why, (if Why = Null_Unbounded_String then "" else ASCII.LF & "")
                          & Line);
               end loop;
               E.Add_Text (Failed, "name", Evidence_Id);
               E.Add_Text (Failed, "detail", To_String (Why));
               Pres.Report (Screen, Failed);
            end;
         end loop;
      end;
      return;
   end if;

   --  The state itself, not the project's files: what does not hold
   --  together, found without a model.
   if Argument (1) = "consistency" and then Argument (2) /= "" then
      Outcome := E.Make (E.Framework_Input_Invalid);
      E.Add_Text (Outcome, "name", "/check consistency");
      E.Add_Text (Outcome, "value", Argument (2));
      E.Add_Text (Outcome, "detail", "it only lists what does not hold together; nothing"
                  & " follows it");
      Pres.Report (Screen, Outcome);
      return;
   elsif Argument (1) = "consistency" then
      declare
         package Cs renames Model_Runner.Framework.Consistency;
         Found : constant Cs.Finding_List := Cs.Check (Store);
      begin
         for Index in 1 .. Cs.Length (Found) loop
            --  What does not hold together, its kind in the colour of
            --  something gone wrong.
            Pres.Put_Marked
              (Screen, "cli.task.item",
               [Loc.Named ("name", To_String (Cs.Element (Found, Index).Subject)),
                --  In words: retired requirement, not retired_requirement.
                Loc.Named ("value", Ada.Strings.Fixed.Translate
                                      (Cs.Kind_Word (Cs.Element (Found, Index).Kind),
                                       Ada.Strings.Maps.To_Mapping ("_", " "))),
                Loc.Named ("detail", To_String (Cs.Element (Found, Index).Detail))],
               Cs.Kind_Word (Cs.Element (Found, Index).Kind), Pres.Bad);
         end loop;
         Pres.Put_Message
           (Screen, "cli.project.consistency", [Loc.Named ("count", Image (Cs.Length (Found)))]);

         --  Something that does not hold together is a check that did
         --  not pass.
         if Cs.Length (Found) > 0 then
            declare
               Failed : E.Error_Info := E.Make (E.Framework_Verification_Failed);
            begin
               E.Add_Text (Failed, "name", "consistency");
               E.Add_Text (Failed, "detail", "what does not hold together in the state, listed"
                           & " above: " & Image (Cs.Length (Found)));
               Pres.Report (Screen, Failed);
            end;
         end if;
      end;
      return;
   end if;

   Config := Model_Runner.Framework.Configurations.Required (Store);
   declare
      --  The profiles to run: the one named; for full, those the
      --  configuration's list verification.full names; otherwise the
      --  default.
      Profiles : Names.Vector;

      procedure Run_One (Profile : String) is
         Evidence : Unbounded_String;
         Passed   : Boolean;
      begin
         Vf.Run_Profile (Store, Change, Profile, "", Evidence, Passed, Outcome);
         if E.Is_Ok (Outcome) then
            S.Commit (Store, Change, Outcome);
         end if;
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            return;
         end if;

         declare
            Said : constant Vf.Diagnostic_List :=
              Vf.Diagnostics_Of (Store, To_String (Evidence));
         begin
            for Index in 1 .. Vf.Length (Said) loop
               Pres.Put_Message
                 (Screen, "cli.task.diagnostic",
                  [Loc.Named ("path",
                              (if Length (Vf.Element (Said, Index).File) = 0
                               then "(" & Profile & ")"
                               else To_String (Vf.Element (Said, Index).File) & ":"
                                    & Image (Vf.Element (Said, Index).Line))),
                   Loc.Named ("severity", To_String (Vf.Element (Said, Index).Severity)),
                   Loc.Named ("detail", To_String (Vf.Element (Said, Index).Message)
                              & (if Length (Vf.Element (Said, Index).Code) = 0 then ""
                                 else " [" & To_String (Vf.Element (Said, Index).Code)
                                      & "]"))]);
            end loop;
            Pres.Put_Message
              (Screen, "cli.task.verified",
               [Loc.Named ("name", To_String (Evidence)),
                Loc.Named ("value", (if Passed then "passed" else "failed")),
                Loc.Named ("count", Image (Vf.Length
                             (Vf.Parse_Profile (R.Get (Config, "profile." & Profile))))),
                Loc.Named ("total", Image (Vf.Length (Said)))]);
         end;

         --  New evidence: the requirements are judged again, and said
         --  after what the checks found.
         declare
            Changed : Names.Vector;
         begin
            Vf.Reevaluate_Requirements (Store, Change, Changed, Outcome);
            if E.Is_Ok (Outcome) then
               S.Commit (Store, Change, Outcome);
            end if;
            for Requirement of Changed loop
               Pres.Put_Message
                 (Screen, "cli.work.requirement",
                  [Loc.Named ("name", Requirement),
                   Loc.Named ("value", Nt.State_Of (Store, Nt.Requirement, Requirement))]);
            end loop;
            Outcome := E.Success;
         end;

         --  A pass of a suite that holds no tests yet: said, so that
         --  it is not read as tests that pass.
         if Passed and then Vf.Found_No_Tests (Store, To_String (Evidence)) then
            Pres.Put_Note (Screen, "cli.check.no_tests_yet",
                        [Loc.Named ("name", Profile),
                         --  A test task open already: that, not another.
                         Loc.Named ("detail",
                                    (if Model_Runner.Framework.Tasks.First_Open_Of_Kind (Store, "test") /= ""
                                     then "/work " & Model_Runner.Framework.Tasks.First_Open_Of_Kind
                                                       (Store, "test") & " writes one"
                                     else "a test task, /task new TITLE kind=test, writes the first"))]);
         end if;

         --  A profile that runs no tests, said so, with what does.
         --  Not when others that run them run with it.
         if R.Get (Config, "scalar.profile_capability." & Profile) /= "run_tests"
           and then not (for some Other of Profiles =>
                           R.Get (Config, "scalar.profile_capability." & Other) = "run_tests")
         then
            Pres.Put_Note (Screen, "cli.check.no_tests", [Loc.Named ("name", Profile)]);
         end if;

         --  Not passed: a failure, with what failed and how it ended.
         if not Passed then
            declare
               Failed : E.Error_Info := E.Make (E.Framework_Verification_Failed);
               Why    : Unbounded_String;
            begin
               for Line of Vf.Why_Failed (Store, To_String (Evidence)) loop
                  Append (Why, (if Why = Null_Unbounded_String then "" else ASCII.LF & "")
                          & Line);
               end loop;
               E.Add_Text (Failed, "name", To_String (Evidence));
               E.Add_Text (Failed, "detail", To_String (Why));
               Pres.Report (Screen, Failed);
            end;
            --  Its commands may be the wrong ones: where they are set.
            Pres.Put_Note (Screen, "cli.check.profile_change",
                           [Loc.Named ("name", Profile),
                            Loc.Named ("value", R.Get (Config, "profile." & Profile))]);
         end if;
      end Run_One;
   begin
      if Argument (1) = "full" and then not R.Has (Config, "profile.full") then
         for Name of Model_Runner.Framework.Lines_Of (R.Get (Config, "list.verification.full")) loop
            if R.Has (Config, "profile." & Name) then
               Profiles.Append (Name);
            end if;
         end loop;
      elsif Argument (1) /= "" and then R.Has (Config, "profile." & Argument (1)) then
         Profiles.Append (Argument (1));
      elsif Argument (1) /= "" then
         --  Not one: said with those there are.
         declare
            Named : Unbounded_String;
         begin
            for Index in 1 .. R.Field_Count (Config) loop
               declare
                  Field_Name : constant String := R.Field_Name (Config, Index);
               begin
                  if Field_Name'Length > 8
                    and then Field_Name (Field_Name'First .. Field_Name'First + 7) = "profile."
                  then
                     Append (Named, (if Named = Null_Unbounded_String then "" else ", ")
                             & Field_Name (Field_Name'First + 8 .. Field_Name'Last));
                  end if;
               end;
            end loop;
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "what to check");
            E.Add_Text (Outcome, "value", Argument (1));
            E.Add_Text (Outcome, "detail", "it is a profile (" & To_String (Named)
                        & "), full, consistency or a requirement");
            Pres.Report (Screen, Outcome);
         end;
         return;
      end if;
      if Profiles.Is_Empty and then R.Get (Config, "scalar.verification.default") /= "" then
         Profiles.Append (R.Get (Config, "scalar.verification.default"));
      end if;
      if Profiles.Is_Empty then
         Outcome := E.Make (E.Framework_Not_Found);
         E.Add_Text (Outcome, "name", "a verification profile -- verification.default names none;"
                     & " /reconfigure verification.default=PROFILE names one");
         Pres.Report (Screen, Outcome);
         return;
      end if;
      --  A profile whose every check another in the list runs too is
      --  not run twice: what it would find, that one finds.
      declare
         function Checks_Of (Profile : String) return Names.Vector is
            Result : Names.Vector;
            Parsed : constant Vf.Check_List :=
              Vf.Parse_Profile (R.Get (Config, "profile." & Profile));
         begin
            for Index in 1 .. Vf.Length (Parsed) loop
               Result.Append (To_String (Vf.Element (Parsed, Index).Command));
            end loop;
            return Result;
         end Checks_Of;

         Kept : Names.Vector;
      begin
         for Profile of Profiles loop
            if Checks_Of (Profile).Is_Empty
              or else not (for some Other of Profiles =>
                      Other /= Profile
                      and then (for all Command of Checks_Of (Profile) =>
                                  Checks_Of (Other).Contains (Command))
                      and then Natural (Checks_Of (Other).Length)
                                 > Natural (Checks_Of (Profile).Length))
            then
               Kept.Append (Profile);
            end if;
         end loop;
         Profiles := Kept;
      end;
      for Profile of Profiles loop
         Run_One (Profile);
         exit when E.Is_Error (Outcome);
      end loop;
   end;
end Check;
