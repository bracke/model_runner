separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Instruct (Store : in out S.Store) is
   package Au renames Model_Runner.Framework.Authority;
   Change : S.Transaction;
   Said   : Unbounded_String;
   Id     : Unbounded_String;
begin
   for Index in 2 .. Natural (All_Words.Length) loop
      Append (Said, (if Index = 2 then "" else " ") & All_Words (Index));
   end loop;
   if Said = Null_Unbounded_String then
      for Line of Au.Standing_Instructions (Store) loop
         Pres.Put_Message (Screen, "cli.task.field",
                           [Loc.Named ("name", Line (Line'First .. Ada.Strings.Fixed.Index (Line, ":") - 1)),
                            Loc.Named ("value", Line (Ada.Strings.Fixed.Index (Line, ":") + 2 .. Line'Last))]);
      end loop;
      if Au.Standing_Instructions (Store).Is_Empty then
         Pres.Put_Note (Screen, "cli.project.instruct.none");
      end if;
      return;
   elsif Argument (1) = "withdraw" then
      Au.Withdraw (Store, Change, Argument (2), Model_Runner.Framework.Transitions.User,
                   Outcome);
      if E.Is_Ok (Outcome) then
         S.Commit (Store, Change, Outcome);
      end if;
      --  Withdrawn already: nothing to do, and said so.
      if E."=" (Outcome.Code, E.Framework_Transition_Invalid) then
         Pres.Put_Note (Screen, "cli.intent.already",
                        [Loc.Named ("name", Argument (2)), Loc.Named ("value", "withdrawn")]);
         return;
      elsif E.Is_Error (Outcome) then
         Pres.Report (Screen, Outcome);
      else
         Pres.Put_Message (Screen, "cli.task.moved",
                           [Loc.Named ("name", Argument (2)),
                            Loc.Named ("value", "withdrawn")]);
      end if;
      return;
   end if;
   declare
      Text      : constant String := To_String (Said);
      Equals    : constant Natural := Ada.Strings.Fixed.Index (Text, "=");
      Overrides : constant Natural := Ada.Strings.Fixed.Index (Text, " overriding ");
      Subject   : constant String :=
        (if Equals = 0 then "" else Ada.Strings.Fixed.Trim (Text (Text'First .. Equals - 1), Ada.Strings.Both));
      Value     : constant String :=
        (if Equals = 0 then ""
         else Ada.Strings.Fixed.Trim
                (Text (Equals + 1 .. (if Overrides > Equals then Overrides - 1 else Text'Last)),
                 Ada.Strings.Both));
      Over      : constant String :=
        (if Overrides > Equals then Ada.Strings.Fixed.Trim (Text (Overrides + 12 .. Text'Last), Ada.Strings.Both)
         else "");
      --  The settings the subject may name: the configuration's, by
      --  their whole names or without their kind, and those the
      --  harness reads.
      function Known_Subjects return Names.Vector is
         Config : R.Item;
         Result : Names.Vector;

         procedure Add (Name : String) is
            Dot : constant Natural := Ada.Strings.Fixed.Index (Name, ".");
         begin
            if not Result.Contains (Name) then
               Result.Append (Name);
            end if;
            if Dot > 0 and then not Result.Contains (Name (Dot + 1 .. Name'Last)) then
               Result.Append (Name (Dot + 1 .. Name'Last));
            end if;
            --  A baseline by its subject: baseline.project.scope is scope.
            if Ada.Strings.Fixed.Index (Name, "baseline.") = Name'First then
               declare
                  Last_Dot : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
               begin
                  if not Result.Contains (Name (Last_Dot + 1 .. Name'Last)) then
                     Result.Append (Name (Last_Dot + 1 .. Name'Last));
                  end if;
               end;
            end if;
         end Add;
      begin
         Config := Model_Runner.Framework.Configurations.Required (Store);
         for Index in 1 .. R.Field_Count (Config) loop
            Add (R.Field_Name (Config, Index));
         end loop;
         for Name of Model_Runner.Framework.Configurations.Known_Names loop
            Add (Name);
         end loop;
         return Result;
      end Known_Subjects;
   begin
      --  An instruction is SUBJECT = VALUE: words alone name nothing it
      --  could stand above.
      if Equals = 0 or else Subject = "" then
         Outcome := E.Make (E.Framework_Input_Missing);
         E.Add_Text (Outcome, "name", "the subject: an instruction is SUBJECT = VALUE, as"
                     & " /instruct documentation = every public operation gets a comment");
         Pres.Report (Screen, Outcome);
         return;
      end if;
      --  What agents may do is the permissions', which an instruction
      --  would only contradict: refused, with where it is changed.
      if (for some One in Model_Runner.Framework.Permissions.Capability =>
            Model_Runner.Framework.Permissions.Word (One) = Subject)
      then
         --  A capability by its word alone: the project's.
         Outcome := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Outcome, "name", "an instruction's subject");
         E.Add_Text (Outcome, "value", Subject);
         declare
            --  A decision ruling it over the configuration: that first.
            Ruler : Unbounded_String;
         begin
            for Dec of Nt.List (Store, Nt.Decision) loop
               if Nt.State_Of (Store, Nt.Decision, Dec) = Tk.Accepted
                 and then Ada.Strings.Fixed.Index (Nt.Governs (Store, Nt.Decision, Dec),
                                                   "map.permission.project." & Subject & " = ") = 1
                 and then Ada.Strings.Fixed.Index (Nt.Governs (Store, Nt.Decision, Dec), "(over CONFIG") > 0
               then
                  Ruler := To_Unbounded_String (Dec);
               end if;
            end loop;
            if Ruler /= Null_Unbounded_String then
               E.Add_Text (Outcome, "detail",
                           "what agents may do is not instructed but granted, and " & To_String (Ruler)
                           & " rules it over the configuration: /decision govern " & To_String (Ruler)
                           & " map.permission.project." & Subject & " none takes that ruling off first, or"
                           & " /decision obsolete " & To_String (Ruler) & " retires it; then /reconfigure"
                           & " map.permission.project." & Subject & "="
                           & (if Value in "on" | "off" | "inherit" then Value else "on") & " changes it");
               Pres.Report (Screen, Outcome);
               return;
            end if;
         end;
         E.Add_Text (Outcome, "detail",
                     "what agents may do is not instructed but granted: /reconfigure map.permission.project."
                     & Subject & "="
                     --  Words that keep it from something: off, or its places.
                     & (if Value in "on" | "off" | "inherit" then Value
                        elsif Subject in "read_source" | "write_source" | "read_specs" | "write_specs"
                        then "off withholds it, =roots=DIR|DIR narrows it, =deny=DIR keeps it out of one,"
                        else "off withholds it,")
                     & " for every task -- /task grant or /task withhold ID " & Subject
                     & " for one");
         Pres.Report (Screen, Outcome);
         return;
      elsif Ada.Strings.Fixed.Index (Subject, "permission.") = Subject'First
        or else Ada.Strings.Fixed.Index (Subject, "map.permission.") = Subject'First
      then
         Outcome := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Outcome, "name", "an instruction's subject");
         E.Add_Text (Outcome, "value", Subject);
         declare
            --  permission.CAP is the project level's: permission.project.CAP.
            Bare  : constant String :=
              (if Ada.Strings.Fixed.Index (Subject, "map.") = Subject'First
               then Subject (Subject'First + 4 .. Subject'Last) else Subject);
            Rest  : constant String := Bare (Bare'First + 11 .. Bare'Last);
            Whole : constant String :=
              (if Ada.Strings.Fixed.Index (Rest, ".") = 0 then "permission.project." & Rest else Bare);
            --  A decision that rules it over the configuration: that
            --  first, as /reconfigure would be refused.
            Ruler : Unbounded_String;
         begin
            for Dec of Nt.List (Store, Nt.Decision) loop
               if Nt.State_Of (Store, Nt.Decision, Dec) = Tk.Accepted
                 and then Ada.Strings.Fixed.Index (Nt.Governs (Store, Nt.Decision, Dec), "map." & Whole & " = ")
                          = 1
                 and then Ada.Strings.Fixed.Index (Nt.Governs (Store, Nt.Decision, Dec), "(over CONFIG") > 0
               then
                  Ruler := To_Unbounded_String (Dec);
               end if;
            end loop;
            E.Add_Text (Outcome, "detail",
                        "what agents may do is not instructed but granted: "
                        & (if Ruler /= Null_Unbounded_String
                           then To_String (Ruler) & " rules it over the configuration, so /decision govern "
                                & To_String (Ruler) & " map." & Whole & " none takes that ruling off first,"
                                & " or /decision obsolete " & To_String (Ruler) & " retires it; then "
                           else "")
                        & "/reconfigure map."
                        & Whole & "=" & (if Value in "on" | "off" | "inherit" then Value else "on")
                        & " changes it");
         end;
         Pres.Report (Screen, Outcome);
         return;
      end if;
      --  A setting the harness reads is set or ruled, not told: an
      --  instruction would be read by agents and kept by nothing.
      declare
         Setting : constant String :=
           (if Model_Runner.Framework.Configurations.Known_Names.Contains (Subject) then Subject
            elsif Model_Runner.Framework.Configurations.Known_Names.Contains ("scalar." & Subject)
            then "scalar." & Subject
            elsif Model_Runner.Framework.Configurations.Known_Names.Contains ("set." & Subject)
            then "set." & Subject
            elsif Ada.Strings.Fixed.Index (Subject, "scalar.") = Subject'First then Subject
            else "");
      begin
         if Setting /= "" then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "an instruction's subject");
            E.Add_Text (Outcome, "value", Subject);
            E.Add_Text (Outcome, "detail",
                        Setting & " is a setting, set rather than instructed: /reconfigure " & Setting & "="
                        & Value & " sets it, or /decision govern DEC-ID " & Setting & " " & Value
                        & " rules it");
            Pres.Report (Screen, Outcome);
            return;
         end if;
      end;
      --  What it overrides is an entry there is and stands.
      if Over /= "" then
         declare
            Upper : constant String := Ada.Characters.Handling.To_Upper (Over);
            State : constant String :=
              (if Nt.State_Of (Store, Nt.Decision, Upper) /= "" then Nt.State_Of (Store, Nt.Decision, Upper)
               elsif Nt.State_Of (Store, Nt.Specification, Upper) /= ""
               then Nt.State_Of (Store, Nt.Specification, Upper)
               else Nt.State_Of (Store, Nt.Requirement, Upper));
         begin
            if State = "" or else State in "obsolete" | "superseded" | "rejected" then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "what it overrides");
               E.Add_Text (Outcome, "value", Over);
               E.Add_Text (Outcome, "detail",
                           (if State = "" then "it is no decision, specification or requirement the"
                                               & " project holds"
                            else Upper & " is " & State & ", and overrides nothing now"));
               Pres.Report (Screen, Outcome);
               return;
            end if;
         end;
      end if;
      --  One on the same subject stands already: named, with how to
      --  take it back -- two that say different things both stand.
      for Line of Au.Standing_Instructions (Store) loop
         declare
            Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ": ");
            Equal : constant Natural := Ada.Strings.Fixed.Index (Line, " = ");
         begin
            --  The same again, now overriding what it did not: the
            --  old one withdrawn and the new one made, said.
            if Colon > 0 and then Equal > Colon
              and then Ada.Characters.Handling.To_Lower (Line (Colon + 2 .. Equal - 1))
                       = Ada.Characters.Handling.To_Lower (Subject)
              and then Plain_Words (Line (Equal + 3 .. Line'Last)) = Plain_Words (Value)
              and then Over /= ""
              and then Ada.Strings.Fixed.Index (Line, Ada.Characters.Handling.To_Upper (Over)) = 0
            then
               Au.Withdraw (Store, Change, Line (Line'First .. Colon - 1),
                            Model_Runner.Framework.Transitions.User, Outcome);
               if E.Is_Error (Outcome) then
                  Pres.Report (Screen, Outcome);
                  return;
               end if;
               Pres.Put_Note (Screen, "cli.project.instruct.now_overriding",
                              [Loc.Named ("name", Line (Line'First .. Colon - 1)),
                               Loc.Named ("value", Ada.Characters.Handling.To_Upper (Over))]);
            --  Saying the same again: nothing new, and nothing made.
            elsif Colon > 0 and then Equal > Colon
              and then Ada.Characters.Handling.To_Lower (Line (Colon + 2 .. Equal - 1))
                       = Ada.Characters.Handling.To_Lower (Subject)
              and then Plain_Words (Line (Equal + 3 .. Line'Last)) = Plain_Words (Value)
            then
               Pres.Put_Note (Screen, "cli.project.instruct.same_already",
                              [Loc.Named ("name", Line (Line'First .. Colon - 1))]);
               return;
            elsif Colon > 0 and then Equal > Colon
              and then Line (Colon + 2 .. Equal - 1) = Subject
            then
               Pres.Put_Note (Screen, "cli.project.instruct.same_subject",
                              [Loc.Named ("name", Line (Line'First .. Colon - 1)),
                               Loc.Named ("value", Line (Equal + 3 .. Line'Last)),
                               Loc.Named ("other", Subject)]);
            end if;
         end;
      end loop;
      Au.Instruct (Store, Change, Subject, Value, Over,
                   Model_Runner.Framework.Transitions.User, Id, Outcome);
      if E.Is_Ok (Outcome) then
         S.Commit (Store, Change, Outcome);
      end if;
      if E.Is_Error (Outcome) then
         Pres.Report (Screen, Outcome);
      else
         Pres.Put_Message (Screen, "cli.task.created",
                           [Loc.Named ("name", To_String (Id)),
                            Loc.Named ("detail", Subject & " = " & Value)]);
         --  What it does and does not do: agents are told it above
         --  every other source; a setting it names is not changed by it.
         declare
            Known : constant Names.Vector := Known_Subjects;
            Near  : constant String := Model_Runner.Framework.Nearest (Subject, Known);
         begin
            if not Known.Contains (Subject)
              and then Ada.Strings.Fixed.Index (Subject, "permission.") /= Subject'First
            then
               Pres.Put_Note (Screen, "cli.project.instruct.unknown",
                              [Loc.Named ("name", Subject),
                               Loc.Named ("detail", (if Near = "" then ""
                                                     else "; did you mean " & Near & "?"))]);
            end if;
            --  A setting of the harness's it names is not changed by it:
            --  said, with what changes it; a free subject is only told.
            if Known.Contains (Subject)
              and then not (for some Name of Known =>
                              Ada.Strings.Fixed.Index (Name, "baseline.") = Name'First
                              and then Ada.Strings.Fixed.Tail (Name, Subject'Length + 1) = "." & Subject)
            then
               Pres.Put_Note (Screen, "cli.project.instruct.advisory", [Loc.Named ("name", Subject)]);
            end if;
         end;
      end if;
   end;
end Instruct;
