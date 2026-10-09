separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Show_Config (Store : in out S.Store) is
   Config : R.Item;
   Read   : E.Error_Info;

   --  What an accepted decision rules for a setting, by the setting:
   --  shown beside what the configuration says, and the two named
   --  where they disagree.
   Ruled  : Model_Runner.Framework.Configurations.Value_Maps.Map;

   --  The setting an input made, where it holds something else now:
   --  input.work_isolation's is scalar.work.isolation.
   function Since_Init (Name, Given : String) return String is
      Dotted : constant String :=
        Ada.Strings.Fixed.Translate (Name (Name'First + 6 .. Name'Last),
                                     Ada.Strings.Maps.To_Mapping ("_", "."));
   begin
      for Kind_Of in 1 .. 2 loop
         declare
            Setting : constant String := (if Kind_Of = 1 then "scalar." else "set.") & Dotted;
         begin
            if R.Has (Config, Setting) and then R.Get (Config, Setting) /= Given then
               return "; " & Setting & " is " & R.Get (Config, Setting) & " now";
            end if;
         end;
      end loop;
      return "";
   end Since_Init;

   --  Whether what rules a setting says what it holds: the last ruling
   --  named -- a decision's, or an instruction's -- is its value.
   function Agrees (Said, Value : String) return Boolean is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Said);
      Want  : constant String := Ada.Characters.Handling.To_Lower (Value);
   begin
      return (Lower'Length >= Want'Length + 7
              and then Lower (Lower'Last - Want'Length - 6 .. Lower'Last) = " rules " & Want)
        or else (Lower'Length >= Want'Length + 6
                 and then Lower (Lower'Last - Want'Length - 5 .. Lower'Last) = " says " & Want)
        --  A capability granted with no limits is what on rules.
        or else (Want = "" and then Lower'Length > 3 and then Lower (Lower'Last - 2 .. Lower'Last) = " on");
   end Agrees;

   --  A name NAME is asked for by: a word of it, or words of it in
   --  order -- work is scalar.work.lease's, not network's.
   function Asked (Name : String) return Boolean
   is (Argument (1) = ""
       or else Ada.Strings.Fixed.Index ("." & Name & ".", "." & Argument (1)) > 0);

   --  What a setting is about, for the group it is shown in.
   function Area_Of (Name : String) return String is
      function Starts (Prefix : String) return Boolean
      is (Ada.Strings.Fixed.Index (Name, Prefix) = Name'First);
   begin
      return (if Starts ("input.") or else Starts ("template_") or else Name = "configuration_fingerprint"
              then "project"
              elsif Starts ("map.permission.") then "permissions"
              elsif Starts ("scalar.work.") or else Starts ("scalar.agents.")
                or else Starts ("scalar.task.max_") or else Starts ("scalar.task.token_budget")
                or else Starts ("scalar.task.coordination") or else Starts ("scalar.recovery.")
                or else Starts ("scalar.model.") or else Starts ("scalar.context.")
                or else Starts ("map.model.")
              then "work"
              elsif Starts ("profile.") or else Starts ("scalar.verification.")
                or else Starts ("list.verification.") or else Starts ("scalar.profile_capability.")
                or else Starts ("scalar.task.profile.") or else Starts ("set.execution.")
                or else Starts ("scalar.execution.")
              then "verification"
              elsif Starts ("set.components") or else Starts ("map.component.")
                or else Starts ("set.repository.") or else Starts ("scalar.repository.")
              then "components"
              elsif Starts ("scalar.bootstrap.") or else Starts ("set.bootstrap.") then "bootstrap"
              else "rules");
   end Area_Of;

   --  The first group's title, with no blank line above it.
   First_Group : Boolean := True;

   Areas : constant Names.Vector :=
     (if Argument (1) = ""
      then Names.Vector'(["project", "work", "permissions", "verification", "components", "bootstrap",
                          "rules"])
      else Names.Vector'(["all"]));

   function In_Area (Name, Area : String) return Boolean
   is (Area = "all" or else Area_Of (Name) = Area);
begin
   Model_Runner.Framework.Configurations.Read (Store, Config, Read);
   if E.Is_Error (Read) then
      Pres.Report (Screen, Read);
      return;
   end if;
   for Id of Nt.List (Store, Nt.Decision) loop
      if Nt.State_Of (Store, Nt.Decision, Id) = Tk.Accepted then
         declare
            All_Of : Names.Vector := Nt.Also_Governs (Store, Nt.Decision, Id);
         begin
            if Nt.Governs (Store, Nt.Decision, Id) /= "" then
               All_Of.Prepend (Nt.Governs (Store, Nt.Decision, Id));
            end if;
            for One of All_Of loop
               declare
                  Equal : constant Natural := Ada.Strings.Fixed.Index (One, " = ");
                  Over  : constant Natural := Ada.Strings.Fixed.Index (One, " (over ");
               begin
                  if Equal > One'First then
                     Ruled.Include (One (One'First .. Equal - 1),
                                    Id & " rules "
                                    & One (Equal + 3 .. (if Over > 0 then Over - 1 else One'Last)));
                  end if;
               end;
            end loop;
         end;
      end if;
   end loop;
   --  Set out by what each setting is about, a group a title, where
   --  the whole is asked for; a name asked for, as one list.
   --  A standing instruction on a setting, beside what decisions rule:
   --  INSTR-001 says 3, where the setting is agents.max_steps.
   for Line of Model_Runner.Framework.Authority.Standing_Instructions (Store) loop
      declare
         Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ": ");
         Equal : constant Natural := Ada.Strings.Fixed.Index (Line, "=");
      begin
         if Colon > 0 and then Equal > Colon then
            declare
               Subject : constant String :=
                 Ada.Strings.Fixed.Trim (Line (Colon + 2 .. Equal - 1), Ada.Strings.Both);
               Said    : constant String :=
                 Ada.Strings.Fixed.Trim (Line (Equal + 1 .. Line'Last), Ada.Strings.Both);
               Whole   : constant String :=
                 (if R.Has (Config, Subject) then Subject
                  elsif R.Has (Config, "scalar." & Subject)
                    or else Model_Runner.Framework.Configurations.Known_Names.Contains ("scalar." & Subject)
                  then "scalar." & Subject
                  else Subject);
               Id      : constant String := Line (Line'First .. Colon - 1);
            begin
               if Ruled.Contains (Whole) then
                  Ruled.Replace (Whole, Ruled (Whole) & "; " & Id & " says " & Said);
               else
                  Ruled.Include (Whole, Id & " says " & Said);
               end if;
            end;
         end if;
      end;
   end loop;
   Sectioned := Argument (1) = "";
   for Area of Areas loop
      if Argument (1) = ""
        and then ((for some Index in 1 .. R.Field_Count (Config) =>
                     In_Area (R.Field_Name (Config, Index), Area)
                     and then Ada.Strings.Fixed.Index (R.Field_Name (Config, Index), "file.") /= 1)
                  or else Area in "permissions" | "components"
                  or else (for some Known of Model_Runner.Framework.Configurations.Known_Names =>
                             In_Area (Known, Area)))
      then
         if First_Group then
            First_Group := False;
         elsif not Pres.Is_Structured (Screen) then
            Pres.Put_Line (Screen, "");
         end if;
         Pres.Put_Header
           (Screen,
            (if Area = "project" then "cli.config.section.project"
             elsif Area = "work" then "cli.config.section.work"
             elsif Area = "permissions" then "cli.config.section.permissions"
             elsif Area = "verification" then "cli.config.section.verification"
             elsif Area = "components" then "cli.config.section.components"
             elsif Area = "bootstrap" then "cli.config.section.bootstrap"
             else "cli.config.section.rules"));
      end if;
      for Index in 1 .. R.Field_Count (Config) loop
         declare
            Name  : constant String := R.Field_Name (Config, Index);
            Value : constant String := R.Get (Config, Name);

            --  A set's items on one line a comma apart, as the other lines
            --  name several things; a list's -- commands, in order -- a line
            --  each.
            function Shown return String is
            begin
               --  A permission granted with nothing more: said so, not a
               --  bare colon.
               if Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First and then Value = ""
                 and then Name'Length > 12 and then Name (Name'Last - 11 .. Name'Last) = ".write_specs"
               then
                  --  As the other levels' roots read: roots=..., and .md files.
                  return "granted, roots=docs/|doc/|specs/|spec/ and any .md file";
               elsif Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First and then Value = "" then
                  return "granted, no limits";
               --  Inherited: what the project above gives it, said.
               elsif Ada.Strings.Fixed.Index (Name, "map.permission.kind.") = Name'First
                 and then Value = "inherit"
               then
                  declare
                     package Pm renames Model_Runner.Framework.Permissions;
                     Word  : constant String :=
                       Name (Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward) + 1 .. Name'Last);
                     Above : constant Pm.Permission_Set := Pm.Effective (Store, "", "", Within_Sandbox => False);
                  begin
                     for One in Pm.Capability loop
                        if Pm.Word (One) = Word then
                           return "inherit (the project's: "
                             & (if not Above (One).Granted then "withheld"
                                elsif Pm.Grant_Text (Above (One)) = "" then "granted, no limits"
                                else Pm.Grant_Text (Above (One)))
                             & ")";
                        end if;
                     end loop;
                     return "inherit";
                  end;
               elsif not (Name'Length > 4 and then Name (Name'First .. Name'First + 3) in "set." | "list")
               then
                  return Value;
               end if;
               declare
                  Result : Unbounded_String;
                  Start  : Positive := Value'First;
               begin
                  for Index in Value'First .. Value'Last + 1 loop
                     --  A set's items are words: a space parts them as a
                     --  comma does, however they were written.
                     if Index > Value'Last or else Value (Index) in ASCII.LF | ASCII.HT | ','
                       or else (Value (Index) = ' ' and then Name (Name'First .. Name'First + 3) = "set.")
                     then
                        declare
                           Item : constant String :=
                             Ada.Strings.Fixed.Trim (Value (Start .. Index - 1), Ada.Strings.Both);
                        begin
                           if Item /= "" then
                              --  A list's items in order, a comma apart, as
                              --  a set's are: on the one line.
                              Append (Result, (if Result = Null_Unbounded_String then "" else ", ") & Item);
                           end if;
                        end;
                        Start := Index + 1;
                     end if;
                  end loop;
                  return To_String (Result);
               end;
            end Shown;

            --  A kind's or a role's grant the project above withholds:
            --  what it gives is nothing, said beside what it says.
            function Withheld_Note return String is
               package Pm renames Model_Runner.Framework.Permissions;
               Dot     : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
               Word    : constant String := (if Dot = 0 then "" else Name (Dot + 1 .. Name'Last));
               Kind    : constant String :=
                 (if Ada.Strings.Fixed.Index (Name, "map.permission.kind.") = Name'First and then Dot > 20
                  then Name (Name'First + 20 .. Dot - 1) else "");
            begin
               if Kind = "" or else Value in "off" | "inherit" then
                  return "";
               end if;
               --  What the kind ends with, the project's narrowing and
               --  all: nothing, though it says something.
               declare
                  Ends_With : constant Pm.Permission_Set :=
                    Pm.Effective (Store, Kind, "", Within_Sandbox => False);
               begin
                  for One in Pm.Capability loop
                     if Pm.Word (One) = Word and then not Ends_With (One).Granted then
                        return " -- but withheld here all the same: the project above withholds " & Word;
                     --  Granted, narrower than it asks: what it gets.
                     elsif Pm.Word (One) = Word and then Pm.Grant_Text (Ends_With (One)) /= Value
                       and then Pm.Grant_Text (Ends_With (One)) not in "" | "granted"
                     then
                        return " (gets " & Pm.Grant_Text (Ends_With (One)) & ": the project's bound)";
                     end if;
                  end loop;
               end;
               return "";
            end Withheld_Note;

            --  The agents' bound set, where the project's own grant is
            --  lower: the lower is what an agent meets, said beside it.
            function Bound_Note return String is
               package Pm renames Model_Runner.Framework.Permissions;
               Present : Boolean;
               Grant   : constant Pm.Permission_Set := Pm.Level_Of (Config, "project", Present);
               Granted : constant Natural :=
                 (if Name = "scalar.agents.max_children" then Grant (Pm.Create_Children).Max_Children
                  elsif Name = "scalar.agents.max_depth" then Grant (Pm.Create_Children).Max_Depth
                  else Natural'Last);
            begin
               if Granted = Natural'Last or else not Grant (Pm.Create_Children).Granted
                 or else Value'Length not in 1 .. 6 or else not (for all C of Value => C in '0' .. '9')
                 or else Granted >= Natural'Value (Value)
               then
                  return "";
               end if;
               return " (the project's create_children grants " & Image (Granted)
                 & ", and an agent meets the lower: " & Image (Granted) & ")";
            end Bound_Note;
         begin
            --  Those NAME names, when one is given.
            if (Name'Length < 5 or else Name (Name'First .. Name'First + 4) /= "file.")
              and then Asked (Name)
              and then In_Area (Name, Area)
              --  A level's inherited capabilities are said together below.
              and then not (Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First
                            and then Value = "inherit"
                            and then Argument (1) /= Name
                            and then Argument (1) /= Name (Ada.Strings.Fixed.Index
                                                             (Name, ".", Ada.Strings.Backward) + 1
                                                           .. Name'Last))
            then
               --  An input is what /init was given: the settings it made
               --  may have been changed since, and are shown as they are.
               Field (Name, (if Name'Length > 6 and then Name (Name'First .. Name'First + 5) = "input."
                             then Shown & " (given at /init" & Since_Init (Name, Value) & ")"
                             elsif Ruled.Contains (Name)
                             then Shown & " (" & Ruled (Name)
                                  & (if Agrees (Ruled (Name), Value)
                                     then ")"
                                     else "; they disagree -- /check consistency says how to settle it)")
                             else Shown & Bound_Note & Withheld_Note),
                      --  Ruled on, and agreeing, apart from a default;
                      --  disagreeing, as something gone wrong.
                      (if not Ruled.Contains (Name)
                         or else (Name'Length > 6 and then Name (Name'First .. Name'First + 5) = "input.")
                       then Pres.Plain
                       elsif Agrees (Ruled (Name), Value)
                       then Pres.Good
                       else Pres.Bad));
               --  Asked by name: what it does, and what it takes.
               if Argument (1) /= "" and then Model_Runner.Framework.Configurations.Meaning_Of (Name) /= ""
               then
                  Field ("  means", Model_Runner.Framework.Configurations.Meaning_Of (Name), Pres.Muted);
               end if;
            end if;
         end;
      end loop;
      --  The settings the harness reads that are not set: there, with
      --  what holds for them, so the whole is the whole.
      if Argument (1) = "" then
         for Known of Model_Runner.Framework.Configurations.Known_Names loop
            if not R.Has (Config, Known) and then In_Area (Known, Area) then
               Field (Known, (if Model_Runner.Framework.Configurations.Default_Of (Known) = ""
                              then "(not set)"
                              else "(not set: " & Model_Runner.Framework.Configurations.Default_Of (Known)
                                   & ")"),
                      Pres.Muted);
            end if;
         end loop;
         --  A kind's own limits, none set: there too, with what holds.
         if Area = "work" then
            for Limit of Names.Vector'(["max_seconds", "max_tool_calls", "max_steps", "token_budget"]) loop
               if not (for some Index in 1 .. R.Field_Count (Config) =>
                         Ada.Strings.Fixed.Index (R.Field_Name (Config, Index), "scalar.task." & Limit & ".")
                         = 1)
               then
                  Field ("scalar.task." & Limit & ".KIND",
                         "(not set for any kind: agents." & Limit & " holds)", Pres.Muted);
               end if;
            end loop;
         end if;
      end if;
      if Area in "permissions" | "all" then
         --  Each permission level the configuration names: what it takes
         --  from the level above in one line, and each capability it does
         --  not grant said, not left to be missed.
         declare
            package Pm renames Model_Runner.Framework.Permissions;
            Levels : Names.Vector;
         begin
            for Index in 1 .. R.Field_Count (Config) loop
               declare
                  Name : constant String := R.Field_Name (Config, Index);
                  Rest : constant String :=
                    (if Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First
                     then Name (Name'First + 15 .. Name'Last) else "");
                  Dot  : constant Natural := Ada.Strings.Fixed.Index (Rest, ".", Ada.Strings.Backward);
               begin
                  if Dot > Rest'First and then not Levels.Contains (Rest (Rest'First .. Dot - 1)) then
                     Levels.Append (Rest (Rest'First .. Dot - 1));
                  end if;
               end;
            end loop;
            for Level of Levels loop
               declare
                  Whole     : constant String := "map.permission." & Level;
                  Inherited : Unbounded_String;
                  Withheld  : Unbounded_String;
                  Above     : constant Pm.Permission_Set := Pm.Effective (Store, "", "", Within_Sandbox => False);
               begin
                  if Asked (Whole) then
                     for One in Pm.Capability loop
                        declare
                           Field : constant String := Whole & "." & Pm.Word (One);
                        begin
                           --  Inherited from a level that withholds it is
                           --  not had: said apart.
                           if R.Get (Config, Field) = "inherit" and then Level /= "project"
                             and then not Above (One).Granted
                           then
                              Append (Withheld, (if Withheld = Null_Unbounded_String then "" else ", ")
                                                & Pm.Word (One) & " (withheld above)");
                           elsif R.Get (Config, Field) = "inherit" then
                              Append (Inherited, (if Inherited = Null_Unbounded_String then "" else ", ")
                                                 & Pm.Word (One));
                           elsif not R.Has (Config, Field) then
                              Append (Withheld, (if Withheld = Null_Unbounded_String then "" else ", ")
                                                & Pm.Word (One));
                              --  Taken away by a ruling: by which.
                              for Dec of Nt.List (Store, Nt.Decision) loop
                                 if Nt.State_Of (Store, Nt.Decision, Dec) = Tk.Accepted
                                   and then Ada.Strings.Fixed.Index
                                              (Nt.Governs (Store, Nt.Decision, Dec), Field & " = ") = 1
                                 then
                                    Append (Withheld, " (" & Dec & ")");
                                 end if;
                              end loop;
                           end if;
                        end;
                     end loop;
                     if Withheld /= Null_Unbounded_String then
                        Field (Whole & " withholds", To_String (Withheld));
                     end if;
                     if Inherited /= Null_Unbounded_String then
                        Field (Whole & " inherits",
                               To_String (Inherited)
                               & (if Level = "project" then " (the defaults)" else " (from the level above)"));
                     end if;
                  end if;
               end;
            end loop;
         end;
      end if;
      if Area in "permissions" | "all" then
         --  The project's permissions where the configuration says none:
         --  what agents are given all the same.
         if (Argument (1) = "" or else Ada.Strings.Fixed.Index ("map.permission.project", Argument (1)) > 0)
           and then not (for some Index in 1 .. R.Field_Count (Config) =>
                           Ada.Strings.Fixed.Index (R.Field_Name (Config, Index),
                                                    "map.permission.project") = 1)
         then
            declare
               Given : Unbounded_String;
            begin
               for Line of Model_Runner.Framework.Lines_Of
                 (Model_Runner.Framework.Permissions.Image
                    (Model_Runner.Framework.Permissions.Effective
                       (Store, "", "", Within_Sandbox => False)))
               loop
                  Append (Given, (if Given = Null_Unbounded_String then "" else "; ") & Line
                                 --  Specifications with no roots: their own places.
                                 & (if Line = "write_specs"
                                    then " (in " & Model_Runner.Framework.Permissions.Specification_Places
                                         & ")"
                                    else ""));
               end loop;
               Field ("map.permission.project", "(the default) " & To_String (Given));
            end;
         end if;
         --  The level of an agent at work, unset: there to be found,
         --  as messages name it, before it is first written.
         if (Argument (1) = "" or else Ada.Strings.Fixed.Index ("map.permission.role.worker", Argument (1)) > 0)
           and then not (for some Index in 1 .. R.Field_Count (Config) =>
                           Ada.Strings.Fixed.Index (R.Field_Name (Config, Index),
                                                    "map.permission.role.worker") = 1)
         then
            Field ("map.permission.role.worker",
                   "(not set: an agent at work has what its task's kind gives -- "
                   & "/reconfigure map.permission.role.worker.CAPABILITY=off narrows every one)");
         end if;
      end if;
      if Area in "components" | "all" then
         --  The components tasks may name, however each was declared:
         --  listed in set.components or placed with map.component.
         if Argument (1) = "" or else Ada.Strings.Fixed.Index ("components", Argument (1)) > 0 then
            declare
               Named : Unbounded_String;
            begin
               for One of Tk.Components (Store) loop
                  Append (Named, (if Named = Null_Unbounded_String then "" else ", ") & One);
               end loop;
               Field ("components (listed or placed)", To_String (Named));
               --  Open tasks that name a component the project no longer has.
               declare
                  Stray : Unbounded_String;
               begin
                  for Id of Tk.List (Store) loop
                     declare
                        Defined : R.Item;
                        Got     : E.Error_Info;
                     begin
                        Tk.Definition (Store, Id, Defined, Got);
                        if E.Is_Ok (Got) and then R.Get (Defined, "component") /= ""
                          and then not Tk.Components (Store).Contains (R.Get (Defined, "component"))
                          and then Tk.State_Of (Store, Id) not in "complete" | "cancelled" | "rejected"
                        then
                           Append (Stray, (if Stray = Null_Unbounded_String then "" else ", ")
                                   & Id & " in " & R.Get (Defined, "component"));
                        end if;
                     end;
                  end loop;
                  if Stray /= Null_Unbounded_String then
                     Field ("tasks in no component of the project", To_String (Stray));
                  end if;
               end;
            end;
         end if;
      end if;
   end loop;

   --  Settings a name picks out that are not set: said so, as they
   --  mean something unset too.
   if Argument (1) /= "" then
      for Known of Model_Runner.Framework.Configurations.Known_Names loop
         if Ada.Strings.Fixed.Index (Known, Argument (1)) > 0 and then not R.Has (Config, Known)
         then
            --  Not set, and what that means. The agents' bounds hold
            --  with the project's create_children grant below them,
            --  and the lower of the two is what an agent meets.
            declare
               Default : constant String :=
                 Model_Runner.Framework.Configurations.Default_Of (Known);
               package Pm renames Model_Runner.Framework.Permissions;
               Grant   : constant Pm.Permission_Set :=
                 Pm.Effective (Store, "", "", Within_Sandbox => False);
               Granted : constant Natural :=
                 (if Known = "scalar.agents.max_children"
                  then Grant (Pm.Create_Children).Max_Children
                  elsif Known = "scalar.agents.max_depth"
                  then Grant (Pm.Create_Children).Max_Depth
                  else Natural'Last);
            begin
               Field (Known,
                      (if Ruled.Contains (Known) then "(" & Ruled (Known)
                                                       & ", which does not set it) "
                       else "")
                      & (if Default = "" then "(not set)"
                       else "(not set: " & Default
                            & (if Granted /= Natural'Last and then Grant (Pm.Create_Children).Granted
                                 and then (for all C of Default => C in '0' .. '9')
                               then "; the project's create_children grants "
                                    & Image (Granted) & ", and an agent meets the lower: "
                                    & Image (Natural'Min (Granted, Natural'Value (Default)))
                               else "")
                            & ")"));
               --  What it does, and what it takes, asked by name.
               if Model_Runner.Framework.Configurations.Meaning_Of (Known) /= "" then
                  Field ("  means", Model_Runner.Framework.Configurations.Meaning_Of (Known), Pres.Muted);
               end if;
            end;
         end if;
      end loop;
      --  A setting each kind may have its own of, none set for what is
      --  asked: said what holds instead, not that there is no such
      --  setting -- and a kind the project has not, said so.
      declare
         --  What the project gives of a capability, by its word.
         function Project_Grant_Of (Word : String) return String is
            package Pm renames Model_Runner.Framework.Permissions;
            Above : constant Pm.Permission_Set := Pm.Effective (Store, "", "", Within_Sandbox => False);
         begin
            for One in Pm.Capability loop
               if Pm.Word (One) = Word then
                  return (if not Above (One).Granted then "withheld"
                          elsif Pm.Grant_Text (Above (One)) in "" | "granted" then "granted, no limits"
                          else Pm.Grant_Text (Above (One)));
               end if;
            end loop;
            return "";
         end Project_Grant_Of;
      begin
         for Family of Names.Vector'
           (["task.max_seconds", "task.max_tool_calls", "task.max_steps", "task.token_budget",
             "task.coordination", "task.profile", "permission.kind"])
         loop
            if ((Argument (1)'Length >= 8 and then Ada.Strings.Fixed.Index (Family, Argument (1)) > 0)
                or else Ada.Strings.Fixed.Index (Argument (1), Family) > 0)
              and then not (for some Index in 1 .. R.Field_Count (Config) =>
                              Ada.Strings.Fixed.Index (R.Field_Name (Config, Index), Argument (1)) > 0)
            then
               declare
                  At_Family : constant Natural := Ada.Strings.Fixed.Index (Argument (1), Family & ".");
                  Kind      : constant String :=
                    (if At_Family = 0 then ""
                     else Argument (1) (At_Family + Family'Length + 1 .. Argument (1)'Last));
                  Bare_Kind : constant String :=
                    (if Ada.Strings.Fixed.Index (Kind, ".") > 0
                     then Kind (Kind'First .. Ada.Strings.Fixed.Index (Kind, ".") - 1) else Kind);
               begin
                  if Bare_Kind /= "" and then not Tk.Kinds (Store).Contains (Bare_Kind) then
                     Field (Argument (1), "(no kind of task is called " & Bare_Kind & "; they are "
                            & Joined_Names (Tk.Kinds (Store)) & ")");
                  elsif Family = "permission.kind" and then Kind'Length > Bare_Kind'Length
                    and then not (for some One in Model_Runner.Framework.Permissions.Capability =>
                                    Model_Runner.Framework.Permissions.Word (One)
                                    = Kind (Kind'First + Bare_Kind'Length + 1 .. Kind'Last))
                  then
                     Field (Argument (1), "(no capability is called "
                            & Kind (Kind'First + Bare_Kind'Length + 1 .. Kind'Last) & ")");
                  --  One capability of a kind that names others: withheld,
                  --  for a kind grants only what it names.
                  elsif Family = "permission.kind" and then Bare_Kind /= ""
                    and then Kind'Length > Bare_Kind'Length
                    and then (for some Index in 1 .. R.Field_Count (Config) =>
                                Ada.Strings.Fixed.Index (R.Field_Name (Config, Index),
                                                         "map.permission.kind." & Bare_Kind & ".") = 1
                                or else R.Field_Name (Config, Index) = "map.permission.kind." & Bare_Kind)
                  then
                     Field ("map.permission.kind." & Kind,
                            (if Ruled.Contains ("map.permission.kind." & Kind)
                             then "withheld (" & Ruled ("map.permission.kind." & Kind) & ")"
                             else "withheld (kind." & Bare_Kind & " grants only what it names)"), Pres.Bad);
                  else
                     --  Asked of one capability: said of it, not of the kind.
                     Field ((if Family = "permission.kind" then "map." else "scalar.") & Family
                            & (if Bare_Kind = "" then ".KIND"
                               elsif Family = "permission.kind" and then Kind'Length > Bare_Kind'Length
                               then "." & Kind
                               else "." & Bare_Kind),
                            --  A ruling on it, where one is: said first.
                            (if Bare_Kind /= ""
                               and then Ruled.Contains ((if Family = "permission.kind" then "map." else "scalar.")
                                                        & Family & "." & Bare_Kind)
                             then "(" & Ruled ((if Family = "permission.kind" then "map." else "scalar.")
                                               & Family & "." & Bare_Kind) & ", which does not set it) "
                             else "")
                            & (if Family = "permission.kind" and then Kind'Length > Bare_Kind'Length
                             then "(not set: the kind takes the project's -- "
                                  & Project_Grant_Of (Kind (Kind'First + Bare_Kind'Length + 1 .. Kind'Last)) & ")"
                             elsif Family = "permission.kind"
                             then "(not set" & (if Bare_Kind = "" then " for any kind" else "")
                                  & ": the kind takes the project's permissions)"
                             elsif Family = "task.profile"
                             then "(not set" & (if Bare_Kind = "" then " for any kind" else "")
                                  & ": verification.default is what checks it)"
                             else "(not set" & (if Bare_Kind = "" then " for any kind" else "")
                                  & ": agents." & Family (Family'First + 5 .. Family'Last) & " holds)"));
                  end if;
               end;
               return;
            end if;
         end loop;
      end;
      --  Model profiles, none set: the one built in.
      if Ada.Strings.Fixed.Index ("map.model.default", Argument (1)) > 0
        and then Ada.Strings.Fixed.Index (Argument (1), "model") > 0
        and then not R.Has (Config, "map.model.default")
      then
         Field ("map.model.default", "(built in: context=8192, reserve=1024, overhead=0, tools=no,"
                & " structured=yes, reasoning=no, streaming=yes, parallel=no -- a run's context is"
                & " planned with it where scalar.model.default=default names it, else with the session"
                & " model's own; /reconfigure map.model.NAME=context=N,... sets another)");
         return;
      end if;
      --  A capability by its word: what each level grants of it --
      --  the project's, set or by default -- and what rules on it.
      declare
         package Pm renames Model_Runner.Framework.Permissions;
      begin
         for One in Pm.Capability loop
            --  By its word, or as the project's, not written: what holds.
            if Pm.Word (One) = Argument (1)
              or else (not R.Has (Config, "map.permission.project." & Pm.Word (One))
                       and then Argument (1) in "map.permission.project." & Pm.Word (One)
                                              | "permission.project." & Pm.Word (One)
                                              | "project." & Pm.Word (One))
            then
               declare
                  Field_Name   : constant String := "map.permission.project." & Pm.Word (One);
                  Said_Project : Boolean;
                  Of_Project   : constant Pm.Permission_Set :=
                    Pm.Level_Of (Config, "project", Said_Project);
                  Project      : constant Pm.Grant :=
                    (if Said_Project then Of_Project (One) else Pm.Project_Default (One));
               begin
                  --  The kinds that name capabilities and not this one:
                  --  withheld there.
                  for Kind of Tk.Kinds (Store) loop
                     declare
                        Present : Boolean;
                        Level   : constant Pm.Permission_Set := Pm.Level_Of (Config, "kind." & Kind, Present);
                     begin
                        if Present and then not Level (One).Granted
                          and then not R.Has (Config, "map.permission.kind." & Kind & "." & Pm.Word (One))
                        then
                           Field ("map.permission.kind." & Kind & "." & Pm.Word (One), "withheld", Pres.Bad);
                        --  A kind that grants it itself: what it grants -- where
                        --  its own line above has not said so already.
                        elsif Present
                          and then not R.Has (Config, "map.permission.kind." & Kind & "." & Pm.Word (One))
                        then
                           Field ("map.permission.kind." & Kind & "." & Pm.Word (One),
                                  (if Pm.Grant_Text (Level (One)) in "" | "granted" then "granted, no limits"
                                   else Pm.Grant_Text (Level (One))));
                        --  A kind with nothing of its own takes the project's.
                        elsif not Present then
                           Field ("map.permission.kind." & Kind & "." & Pm.Word (One),
                                  "(not set: the kind takes the project's)", Pres.Muted);
                        end if;
                     end;
                  end loop;
                  if not R.Has (Config, Field_Name) then
                     Field (Field_Name,
                            (if not Project.Granted then "withheld"
                             --  Specifications with no roots: their own places.
                             elsif Pm.Grant_Text (Project) = "" and then Pm."=" (One, Pm.Write_Specs)
                             then "granted, in " & Pm.Specification_Places
                             elsif Pm.Grant_Text (Project) = "" then "granted, no limits"
                             else Pm.Grant_Text (Project))
                            & (if Said_Project then "" else " (the default)")
                            --  Its ruling on the same line, not a second one.
                            & (if Ruled.Contains (Field_Name) then " -- " & Ruled (Field_Name) else ""));
                  end if;
                  for Dec of Nt.List (Store, Nt.Decision) loop
                     declare
                        Rule : constant String := Nt.Governs (Store, Nt.Decision, Dec);
                        Eq   : constant Natural := Ada.Strings.Fixed.Index (Rule, " = ");
                     begin
                        if Nt.State_Of (Store, Nt.Decision, Dec) = Tk.Accepted and then Eq > 0
                          and then Ada.Strings.Fixed.Index (Rule (Rule'First .. Eq - 1),
                                                            "." & Pm.Word (One)) > 0
                          --  The project's, unwritten, said on its line above;
                          --  one written, said beside it there.
                          and then not (Rule (Rule'First .. Eq - 1) = Field_Name
                                        and then not R.Has (Config, Field_Name)
                                        and then Ruled.Contains (Field_Name))
                          and then not R.Has (Config, Rule (Rule'First .. Eq - 1))
                        then
                           declare
                              Over    : constant Natural := Ada.Strings.Fixed.Index (Rule, " (over ");
                              Ruling  : constant String :=
                                Rule (Eq + 3 .. (if Over = 0 then Rule'Last else Over - 1));
                              Holding : constant Boolean :=
                                Pm.Ruling_Agrees (Store, Config, Rule (Rule'First .. Eq - 1), Ruling);
                           begin
                              --  Holding, it is what the line above says: one
                              --  line, with why.
                              Field (Rule (Rule'First .. Eq - 1),
                                     Ruling & " (ruled by " & Dec
                                     & (if Over > 0 then ", over the configuration" else "")
                                     & (if Holding then "; it holds)"
                                        else "; the configuration does not hold it -- /check consistency"
                                             & " says how to settle it)"));
                           end;
                        end if;
                     end;
                  end loop;
               end;
               return;
            end if;
         end loop;
      end;
      --  A name nothing holds: said, not answered with nothing.
      if not (for some Index in 1 .. R.Field_Count (Config) =>
                Ada.Strings.Fixed.Index (R.Field_Name (Config, Index), Argument (1)) > 0)
        and then not (for some Known of Model_Runner.Framework.Configurations.Known_Names =>
                        Ada.Strings.Fixed.Index (Known, Argument (1)) > 0)
        and then Ada.Strings.Fixed.Index ("components", Argument (1)) = 0
        and then Ada.Strings.Fixed.Index ("map.permission.project", Argument (1)) = 0
        and then Ada.Strings.Fixed.Index ("map.permission.role.worker", Argument (1)) = 0
      then
         --  With the nearest name there is, by its letters: a whole
         --  name, or a capability's word.
         declare
            Among : Names.Vector := Model_Runner.Framework.Configurations.Known_Names;
         begin
            for Index in 1 .. R.Field_Count (Config) loop
               Among.Append (R.Field_Name (Config, Index));
            end loop;
            for One in Model_Runner.Framework.Permissions.Capability loop
               Among.Append (Model_Runner.Framework.Permissions.Word (One));
            end loop;
            declare
               Near : constant String :=
                 (if Model_Runner.Framework.Nearest (Argument (1), Among) /= ""
                  then Model_Runner.Framework.Nearest (Argument (1), Among)
                  else Model_Runner.Framework.Nearest ("scalar." & Argument (1), Among));
            begin
               Pres.Put_Note (Screen, "cli.project.config_none",
                              [Loc.Named ("value", Argument (1)),
                               Loc.Named ("detail", (if Near = "" then "" else "; did you mean " & Near & "?"))]);
            end;
         end;
      end if;
   end if;
end Show_Config;
