separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Reconfigure (Store : in out S.Store) is
   package Cf renames Model_Runner.Framework.Configurations;
   Known_Before : Names.Vector;
   Changes  : Cf.Value_Maps.Map;
   Planned  : Cf.Change_Plan;
   Read     : E.Error_Info;
   Revision : Natural;
   --  NAME=VALUE words from one on, into the changes; Failed where
   --  one would not do, said already.
   procedure Settings_From (First : Positive; Failed : out Boolean) is
   begin
      Failed := False;
         declare
            Name  : Unbounded_String;
            Value : Unbounded_String;
            Words_Given : Names.Vector;
         begin
            for Index in First .. Natural (All_Words.Length) loop
               declare
                  Part : constant String := All_Words (Index);
               begin
                  if not Words_Given.Is_Empty
                    and then (Part = "=" or else Part (Part'First) = '='
                              or else Words_Given.Last_Element (Words_Given.Last_Element'Last) = '=')
                    and then Ada.Strings.Fixed.Index (Words_Given.Last_Element, "=")
                               in 0 | Words_Given.Last_Element'Last
                    and then not (Part /= "=" and then Part (Part'First) /= '='
                                  and then Ada.Strings.Fixed.Index (Part, "=") > 0)
                  then
                     Words_Given.Replace_Element
                       (Words_Given.Last_Index, Words_Given.Last_Element & Part);
                  else
                     Words_Given.Append (Part);
                  end if;
               end;
            end loop;
            for Part of Words_Given loop
               declare
                  Equal : constant Natural := Ada.Strings.Fixed.Index (Part, "=");
               begin
                  if Part = "confirm=yes" then
                     null;
                  --  A setting starts: named with its kind, or -- as the
                  --  first word -- named any way at all, to be found or
                  --  refused by name rather than dropped.
                  elsif Is_Setting (Part)
                    and then (Ada.Strings.Fixed.Index (Part (Part'First .. Equal - 1), ".") > 0
                              or else Name = Null_Unbounded_String)
                  then
                     --  NAME+=, NAME-=: said in words now.
                     if Equal > Part'First + 1 and then Part (Equal - 1) in '+' | '-' then
                        Read := E.Make (E.CLI_Invalid_Option_Value);
                        E.Add_Text (Read, "option", Part (Part'First .. Equal));
                        E.Add_Text (Read, "value",
                                    "/reconfigure " & (if Part (Equal - 1) = '+' then "add " else "remove ")
                                    & Part (Part'First .. Equal - 2) & " "
                                    & Part (Equal + 1 .. Part'Last) & " is how items are "
                                    & (if Part (Equal - 1) = '+' then "added to" else "taken out of")
                                    & " a set or a list");
                        Pres.Report (Screen, Read);
                        Failed := True;
                        return;
                     end if;
                     if Name /= Null_Unbounded_String then
                        Changes.Include (To_String (Name), To_String (Value));
                     end if;
                     Name := To_Unbounded_String (Part (Part'First .. Equal - 1));
                     Value := To_Unbounded_String (Part (Equal + 1 .. Part'Last));
                  elsif Name /= Null_Unbounded_String then
                     Append (Value, " " & Part);
                  else
                     --  A name with no value: a value is what a change is.
                     Read := E.Make (E.CLI_Invalid_Option_Value);
                     E.Add_Text (Read, "option", Part);
                     E.Add_Text (Read, "value",
                                 (if Part (Part'First) = '='
                                  then "a setting is named before its =, as NAME=VALUE"
                                  else "a setting is changed as " & Part & "=VALUE; /config "
                                       & Part & " shows what it is"));
                     Pres.Report (Screen, Read);
                     Failed := True;
                     return;
                  end if;
               end;
            end loop;
            if Name /= Null_Unbounded_String then
               Changes.Include (To_String (Name), To_String (Value));
            end if;
         end;
   end Settings_From;
   Failed : Boolean;
begin
   --  Nothing named, or help asked for: how it is used.
   if Natural (All_Words.Length) < 2
     or else All_Words (2) in "--help" | "-h" | "help"
   then
      Pres.Put_Message (Screen, "cli.project.reconfigure.usage");
      return;
   end if;

   --  add NAME A B and remove NAME A: items put into a set or a list,
   --  or taken out of it, the rest of what it holds kept.
   if All_Words (2) in "add" | "remove" then
      if Natural (All_Words.Length) < 4 then
         Read := E.Make (E.Framework_Input_Missing);
         E.Add_Text (Read, "name", "what to " & All_Words (2) & ": /reconfigure " & All_Words (2)
                     & " set.NAME ITEM ..., as /reconfigure " & All_Words (2)
                     & " set.execution.allowed make");
         Pres.Report (Screen, Read);
         return;
      end if;
      declare
         Items : Unbounded_String;
         Rest  : Natural := 0;
      begin
         --  The items, up to the first NAME=: from there, settings
         --  changed in the same step.
         for Index in 4 .. Natural (All_Words.Length) loop
            if All_Words (Index) = "confirm=yes" then
               null;
            elsif Rest = 0 and then Ada.Strings.Fixed.Index (All_Words (Index), "=") > 1 then
               Rest := Index;
            elsif Rest = 0 then
               --  A path typed where the session was started, as the
               --  project names it -- set.bootstrap.sources reads it so.
               declare
                  Word  : constant String := All_Words (Index);
                  Whole : constant String :=
                    (if Below_Top /= Null_Unbounded_String and then Word /= ""
                       and then Word (Word'First) /= '/' and then Ada.Strings.Fixed.Index (Word, "*") = 0
                       and then Ada.Directories.Exists (Hostkit.Fs.Join (To_String (Below_Top), Word))
                     then Ada.Directories.Full_Name (Hostkit.Fs.Join (To_String (Below_Top), Word)) else "");
                  Top   : constant String := Ada.Directories.Full_Name (Here);
               begin
                  Append (Items, (if Items = Null_Unbounded_String then "" else ",")
                          & (if Whole'Length > Top'Length + 1
                               and then Whole (Whole'First .. Whole'First + Top'Length) = Top & "/"
                             then Whole (Whole'First + Top'Length + 1 .. Whole'Last) else Word));
               end;
            end if;
         end loop;
         Changes.Include (String'(All_Words (3)) & (if All_Words (2) = "add" then "+" else "-"),
                          To_String (Items));
         if Rest > 0 then
            Settings_From (Rest, Failed);
            if Failed then
               return;
            end if;
         end if;
      end;
   else
      --  NAME=VALUE, the value running on to the next NAME=: a value of
      --  several words needs no quotes. NAME = VALUE, spaced as
      --  /instruct takes it, is the same.
      Settings_From (2, Failed);
      if Failed then
         return;
      end if;
   end if;

   Cf.Plan_Change (Store, Changes, Planned, Read);
   if E.Is_Error (Read) then
      Pres.Report (Screen, Read);
      return;
   elsif Planned.Changed.Is_Empty then
      Pres.Put_Note (Screen, (if (for some Position in Changes.Iterate =>
                                    Cf.Value_Maps.Element (Position) = "inherit")
                              then "cli.project.reconfigure.nothing_inherit"
                              --  Added to a set that holds it, or taken from
                              --  one that does not: said of the set.
                              elsif (for some Position in Changes.Iterate =>
                                       Cf.Value_Maps.Key (Position) (Cf.Value_Maps.Key (Position)'Last)
                                         in '+' | '-')
                              then "cli.project.reconfigure.nothing_set"
                              else "cli.project.reconfigure.nothing"));
      return;
   end if;
   --  A check the new configuration would not let run: refused now,
   --  with the change that lets it, not found at the next /check.
   declare
      package Vf renames Model_Runner.Framework.Verification;
      package Ex renames Model_Runner.Framework.Execution;
      Rules   : constant Ex.Policy := Ex.Policy_From (Planned.After);
      Before  : constant Ex.Policy := Ex.Policy_From (Planned.Before);
      Missing : Names.Vector;
      Where   : Unbounded_String;
   begin
      for Index in 1 .. R.Field_Count (Planned.After) loop
         declare
            Field : constant String := R.Field_Name (Planned.After, Index);
         begin
            if Ada.Strings.Fixed.Index (Field, "profile.") = Field'First then
               declare
                  Checks : constant Vf.Check_List := Vf.Parse_Profile (R.Get (Planned.After, Field));
               begin
                  for At_Check in 1 .. Vf.Length (Checks) loop
                     declare
                        Command : constant String := To_String (Vf.Element (Checks, At_Check).Command);
                        Words   : constant Names.Vector := Ex.Words_Of (Command);
                     begin
                        --  Only what this change stops: a profile it
                        --  sets, or a program it takes away.
                        if not Words.Is_Empty and then Ex.Refusal (Rules, Command) /= ""
                          and then (Ex.Refusal (Before, Command) = "" or else Changes.Contains (Field))
                          and then Ada.Strings.Fixed.Index (Ex.Refusal (Rules, Command), "not a program") > 0
                          and then not Missing.Contains (Words.First_Element)
                        then
                           Missing.Append (Words.First_Element);
                           Append (Where, (if Where = Null_Unbounded_String then "" else ", ")
                                          & Field & " runs " & Words.First_Element);
                        end if;
                     end;
                  end loop;
               end;
            end if;
         end;
      end loop;
      if not Missing.Is_Empty then
         declare
            Allow : Unbounded_String;
            Asked : Unbounded_String;
         begin
            for One of Missing loop
               Append (Allow, (if Allow = Null_Unbounded_String then "" else ",") & One);
            end loop;
            --  One change that says it all: where execution.allowed is
            --  set in it, the programs added to what it is set to.
            for Position in Changes.Iterate loop
               declare
                  Key   : constant String := Cf.Value_Maps.Key (Position);
                  Value : constant String :=
                    (if Ada.Strings.Fixed.Index (Key, "execution.allowed") > 0
                        and then Key (Key'Last) /= '+' and then Key (Key'Last) /= '-'
                     then Cf.Value_Maps.Element (Position) & ", " & To_String (Allow)
                     else Cf.Value_Maps.Element (Position));
               begin
                  if Ada.Strings.Fixed.Index (Key, "execution.allowed") > 0
                    and then Key (Key'Last) /= '+' and then Key (Key'Last) /= '-'
                  then
                     Allow := Null_Unbounded_String;
                  end if;
                  if Key (Key'Last) in '+' | '-' then
                     Append (Asked, (if Key (Key'Last) = '+' then "add " else "remove ")
                                    & Key (Key'First .. Key'Last - 1) & " "
                                    & Ada.Strings.Fixed.Translate
                                        (Value, Ada.Strings.Maps.To_Mapping (",", " ")) & " ");
                  else
                     Append (Asked, Key & "="
                                    & (if Ada.Strings.Fixed.Index (Value, " ") > 0
                                         or else Ada.Strings.Fixed.Index (Value, ",") > 0
                                       then '"' & Value & '"' else Value) & " ");
                  end if;
               end;
            end loop;
            Outcome := E.Make (E.Framework_Execution_Refused);
            E.Add_Text (Outcome, "name", "the check (" & To_String (Where) & ")");
            E.Add_Text (Outcome, "detail",
                        (if Allow = Null_Unbounded_String
                         then "set.execution.allowed would not let it run; allow it in the same change:"
                              & " /reconfigure " & To_String (Asked)
                         --  One step: the items first, the settings after
                         --  them, as /reconfigure add takes both.
                         else "set.execution.allowed would not let it run; allow it in the same change:"
                              & " /reconfigure add set.execution.allowed "
                              & Ada.Strings.Fixed.Translate
                                  (To_String (Allow), Ada.Strings.Maps.To_Mapping (",", " "))
                              & " " & To_String (Asked)));
            Pres.Report (Screen, Outcome);
            return;
         end;
      end if;
   end;
   --  A setting an accepted decision rules, changed to another value:
   --  said before it is asked, as the disagreement it makes.
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
                  Setting : constant String := (if Equal > One'First then One (One'First .. Equal - 1) else "");
                  Ruling  : constant String :=
                    (if Equal = 0 then "" else One (Equal + 3 .. (if Over > 0 then Over - 1 else One'Last)));
               begin
                  --  Changed as written, or as it holds -- a level
                  --  written whole holds its capabilities in one field.
                  if Setting /= ""
                    and then not Model_Runner.Framework.Permissions.Ruling_Agrees
                                   (Store, Planned.After, Setting, Ruling)
                    and then (R.Get (Planned.After, Setting) /= R.Get (Planned.Before, Setting)
                              or else Model_Runner.Framework.Permissions.Ruling_Agrees
                                        (Store, Planned.Before, Setting, Ruling))
                  then
                     --  One that holds over the configuration keeps holding:
                     --  the change is refused, with the ways to change it.
                     if Over > 0 and then Ada.Strings.Fixed.Index (One (Over .. One'Last), "CONFIG") > 0 then
                        Outcome := E.Make (E.Framework_Input_Invalid);
                        E.Add_Text (Outcome, "name", Setting);
                        --  What it would be, as the change says it where the
                        --  field itself holds nothing of it.
                        declare
                           Would : Unbounded_String := To_Unbounded_String (R.Get (Planned.After, Setting));
                        begin
                           for Line of Planned.Changed loop
                              if Would = Null_Unbounded_String
                                and then Ada.Strings.Fixed.Index (Line, Setting & ": ") = Line'First
                                and then Ada.Strings.Fixed.Index (Line, " -> ") > 0
                              then
                                 Would := To_Unbounded_String
                                   (Line (Ada.Strings.Fixed.Index (Line, " -> ") + 4 .. Line'Last));
                              end if;
                           end loop;
                           E.Add_Text (Outcome, "value", To_String (Would));
                        end;
                        E.Add_Text (Outcome, "detail",
                                    Id & " rules " & Ruling & " over the configuration; /decision govern "
                                    & Id & " " & Setting & " VALUE rules another, /decision govern " & Id
                                    & " " & Setting & " none lets it go, or /decision obsolete "
                                    & Id & " lets the configuration say it again");
                        Pres.Report (Screen, Outcome);
                        return;
                     end if;
                     Pres.Put_Note (Screen, "cli.project.reconfigure.against",
                                    [Loc.Named ("name", Setting), Loc.Named ("value", Id & " rules " & Ruling)]);
                  end if;
               end;
            end loop;
         end;
      end if;
   end loop;
   for Line of Planned.Changed loop
      --  A scalar by the name it is typed with, work.lease, where that
      --  names it alone; the rest whole, as they are typed whole.
      Pres.Put_Message (Screen, "cli.project.reconfigure.changed",
                        [Loc.Named ("name", (if Ada.Strings.Fixed.Index (Line, "scalar.") = Line'First
                                             then Line (Line'First + 7 .. Line'Last) else Line))]);
   end loop;
   for Line of Planned.Impact loop
      Pres.Put_Message (Screen, "cli.project.reconfigure.reaches", [Loc.Named ("name", Line)]);
   end loop;
   --  A value set that nothing here reads does nothing: said, before
   --  it is taken for a change in how the project is checked.
   for Line of Planned.Changed loop
      declare
         Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ":");
         Name  : constant String := (if Colon = 0 then Line else Line (Line'First .. Colon - 1));
         Dot   : constant Natural :=
           (if Name'Length > 7 then Ada.Strings.Fixed.Index (Name (Name'First + 7 .. Name'Last), ".")
            else 0);
         Group : constant String := (if Dot = 0 then Name else Name (Name'First .. Dot));
         Known : constant Names.Vector := Cf.Known_Names;
      begin
         if Name'Length > 7 and then Name (Name'First .. Name'First + 6) = "scalar."
           and then not Known.Contains (Name)
           and then not (for some One of Known =>
                           One'Length > Group'Length
                           and then One (One'First .. One'First + Group'Length - 1) = Group)
         then
            Pres.Put_Note (Screen, "cli.project.reconfigure.unread", [Loc.Named ("name", Name)]);
         end if;
      end;
   end loop;

   --  A kind or a role granted more than the project allows gets
   --  only what the project allows: before any change to permissions
   --  is made, every such level it would leave is said, once, with
   --  each capability it asks too much of and what it gets.
   if (for some Name of Planned.Changed =>
         Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First)
   then
      declare
         package Pm renames Model_Runner.Framework.Permissions;
         Levels  : Names.Vector;
         Said_Project : Boolean;
         Of_Project   : constant Pm.Permission_Set :=
           Pm.Level_Of (Planned.After, "project", Said_Project);
         Project : constant Pm.Permission_Set :=
           (if Said_Project then Of_Project else Pm.Project_Default);
         Said_Before   : Boolean;
         Before_Own    : constant Pm.Permission_Set := Pm.Level_Of (Planned.Before, "project", Said_Before);
         Project_Before : constant Pm.Permission_Set :=
           (if Said_Before then Before_Own else Pm.Project_Default);
      begin
         for Index in 1 .. R.Field_Count (Planned.After) loop
            declare
               Field : constant String := R.Field_Name (Planned.After, Index);
               Rest  : constant String :=
                 (if Field'Length > 15 and then Field (Field'First .. Field'First + 14)
                                               = "map.permission."
                  then Field (Field'First + 15 .. Field'Last) else "");
               Dot   : constant Natural := Ada.Strings.Fixed.Index (Rest, ".", Ada.Strings.Backward);
               Level : constant String := (if Dot = 0 then "" else Rest (Rest'First .. Dot - 1));
            begin
               if Level'Length > 5 and then Level (Level'First .. Level'First + 4) in "kind." | "role."
                 and then not Levels.Contains (Level)
               then
                  Levels.Append (Level);
               end if;
            end;
         end loop;
         for Level of Levels loop
            declare
               Present : Boolean;
               --  What it asks for itself: one it inherits asks for
               --  nothing, and follows what is above.
               function Own_Asked return Pm.Permission_Set is
                  Result : Pm.Permission_Set := Pm.Level_Of (Planned.After, Level, Present);
               begin
                  for One in Pm.Capability loop
                     if R.Get (Planned.After, "map.permission." & Level & "." & Pm.Word (One))
                          = "inherit"
                     then
                        Result (One) := Pm.Nothing (One);
                     end if;
                  end loop;
                  return Result;
               end Own_Asked;
               Given   : constant Pm.Permission_Set := Own_Asked;
               Clipped : constant String := Pm.Clipped (Given, Project);
               --  Only a level this change touches, or one a change
               --  of the project's clips otherwise than it did: the
               --  others said when they were changed.
               Touched : constant Boolean :=
                 (for some Line of Planned.Changed =>
                    Ada.Strings.Fixed.Index (Line, "map.permission." & Level & ".") = Line'First
                    or else Ada.Strings.Fixed.Index (Line, "map.permission." & Level & ":") = Line'First)
                 or else Pm.Clipped (Given, Project_Before) /= Clipped;
            begin
               if Present and then Clipped /= "" and then Touched then
                  Pres.Put_Note
                    (Screen, "cli.project.clipped",
                     [Loc.Named ("name", Level), Loc.Named ("detail", Clipped)]);
               end if;
            end;
         end loop;
      end;
   end if;

   --  A document pattern added that finds nothing: said before it is
   --  asked, not found out at the next /bootstrap.
   declare
      function Items (Text : String) return Names.Vector is
         Result : Names.Vector;
      begin
         for Line of Model_Runner.Framework.Lines_Of
           (Ada.Strings.Fixed.Translate (Text, Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
         loop
            if Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both) /= "" then
               Result.Append (Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both));
            end if;
         end loop;
         return Result;
      end Items;
      Before : constant Names.Vector := Items (R.Get (Planned.Before, "set.bootstrap.sources"));
   begin
      for One of Items (R.Get (Planned.After, "set.bootstrap.sources")) loop
         if not Before.Contains (One)
           and then Model_Runner.Framework.Bootstrap.Documents (Store, One).Is_Empty
         then
            Pres.Put_Note (Screen, "cli.project.sources_match_none", [Loc.Named ("value", One)]);
         end if;
      end loop;
   end;

   --  A grant that held roots and holds none after: the rest of the
   --  project opened to it, said before it is asked.
   for Line of Planned.Changed loop
      if Ada.Strings.Fixed.Index (Line, "map.permission.") = Line'First then
         declare
            Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ": ");
            Arrow : constant Natural := Ada.Strings.Fixed.Index (Line, " -> ");
         begin
            if Colon > 0 and then Arrow > Colon then
               declare
                  Field  : constant String := Line (Line'First .. Colon - 1);
                  Before : constant String := Line (Colon + 2 .. Arrow - 1);
                  After  : constant String := Line (Arrow + 4 .. Line'Last);

                  --  The places a constraint names: roots=a|b gives a, b.
                  function Places (Text, Key : String) return Names.Vector is
                     At_Key : constant Natural := Ada.Strings.Fixed.Index (Text, Key & "=");
                     Result : Names.Vector;
                  begin
                     if At_Key > 0 then
                        declare
                           Stop  : constant Natural :=
                             Ada.Strings.Fixed.Index (Text & " ", " ", At_Key);
                           Said  : constant String := Text (At_Key + Key'Length + 1 .. Stop - 1);
                           Start : Natural := Said'First;
                        begin
                           for Index in Said'First .. Said'Last + 1 loop
                              if Index > Said'Last or else Said (Index) = '|' then
                                 if Index > Start then
                                    Result.Append (Said (Start .. Index - 1));
                                 end if;
                                 Start := Index + 1;
                              end if;
                           end loop;
                        end;
                     end if;
                     return Result;
                  end Places;
                  --  What it reaches now that it did not: a deny dropped,
                  --  or a root added beyond those it had.
                  function Opened return String is
                     Said : Unbounded_String;
                     Old_Roots : constant Names.Vector := Places (Before, "roots");
                  begin
                     for Denied of Places (Before, "deny") loop
                        if not Places (After, "deny").Contains (Denied) then
                           Append (Said, (if Said = Null_Unbounded_String then "" else ", ") & Denied);
                        end if;
                     end loop;
                     if not Old_Roots.Is_Empty then
                        for Root of Places (After, "roots") loop
                           --  A root that is no place opens nothing.
                           if Ada.Directories.Exists (Root)
                             and then not (for some Old of Old_Roots =>
                                     Root'Length >= Old'Length
                                     and then Root (Root'First .. Root'First + Old'Length - 1) = Old)
                           then
                              Append (Said, (if Said = Null_Unbounded_String then "" else ", ") & Root);
                           end if;
                        end loop;
                     end if;
                     return To_String (Said);
                  end Opened;
               begin
                  --  Narrowed in part, or a root more: what opens, named.
                  if Ada.Strings.Fixed.Index (After, "roots=") > 0 and then Opened /= ""
                    and then Ada.Strings.Fixed.Index (After, "off") /= After'First
                  then
                     Pres.Put_Note (Screen, "cli.project.grant_opens",
                                    [Loc.Named ("name", Field), Loc.Named ("detail", Opened)]);
                  elsif ((Ada.Strings.Fixed.Index (Before, "roots=") > 0
                       and then Ada.Strings.Fixed.Index (After, "roots=") = 0)
                      --  Or a deny dropped: what it kept out is open again.
                      or else (Ada.Strings.Fixed.Index (Before, "deny=") > 0
                               and then Ada.Strings.Fixed.Index (After, "deny=") = 0))
                    and then Ada.Strings.Fixed.Index (After, "off") /= After'First
                    --  Taken away is narrower, not wider.
                    and then Ada.Strings.Fixed.Index (After, "withheld") /= After'First
                    and then Ada.Strings.Fixed.Index (After, "none") /= After'First
                    and then Ada.Strings.Fixed.Index (After, "inherit, as the level above gives it: not") = 0
                    and then After /= "(none)"
                  then
                     --  Asked for whole -- on, inherit, the deny taken
                     --  out -- it is said, not advised against.
                     Pres.Put_Note (Screen, "cli.project.grant_widened",
                                    [Loc.Named ("name", Field), Loc.Named ("value", Before),
                                     Loc.Named ("detail",
                                                (if Opened /= "" then Opened & " no longer kept from it"
                                                 elsif Ada.Strings.Fixed.Index (Before, "roots=") > 0
                                                 then "the whole project open to it, not only "
                                                      & Joined_Words (Places (Before, "roots"))
                                                 else After))]);
                  end if;
               end;
            end if;
         end;
      end if;
   end loop;

   --  A kind's own limit above what a decision rules for the agents'
   --  whole: the kind's holds over the ruling, said before it is asked.
   for Limit of Names.Vector'(["max_steps", "max_seconds", "max_tool_calls", "token_budget"]) loop
      for Line of Planned.Changed loop
         if Ada.Strings.Fixed.Index (Line, "scalar.task." & Limit & ".") = Line'First then
            declare
               Name  : constant String := Line (Line'First .. Ada.Strings.Fixed.Index (Line, ":") - 1);
               Given : constant String := R.Get (Planned.After, Name);
            begin
               for Dec of Nt.List (Store, Nt.Decision) loop
                  declare
                     Rule : constant String := Nt.Governs (Store, Nt.Decision, Dec);
                     Lead : constant String := "scalar.agents." & Limit & " = ";
                  begin
                     if Nt.State_Of (Store, Nt.Decision, Dec) = Tk.Accepted
                       and then Ada.Strings.Fixed.Index (Rule, Lead) = Rule'First
                       and then Given'Length in 1 .. 9 and then (for all C of Given => C in '0' .. '9')
                     then
                        declare
                           Ruled_Text : constant String := Rule (Rule'First + Lead'Length .. Rule'Last);
                           Stop : Natural := Ruled_Text'First;
                        begin
                           while Stop <= Ruled_Text'Last and then Ruled_Text (Stop) in '0' .. '9' loop
                              Stop := Stop + 1;
                           end loop;
                           if Stop > Ruled_Text'First
                             and then Natural'Value (Given)
                                      > Natural'Value (Ruled_Text (Ruled_Text'First .. Stop - 1))
                           then
                              --  A ruling that holds over the configuration
                              --  holds over a kind's own limit too: refused,
                              --  as a change to the agents' limit is.
                              if Ada.Strings.Fixed.Index (Rule, " (over ") > 0
                                and then Ada.Strings.Fixed.Index
                                           (Rule (Ada.Strings.Fixed.Index (Rule, " (over ") .. Rule'Last),
                                            "CONFIG") > 0
                              then
                                 Outcome := E.Make (E.Framework_Input_Invalid);
                                 E.Add_Text (Outcome, "name", Name);
                                 E.Add_Text (Outcome, "value", Given);
                                 E.Add_Text (Outcome, "detail",
                                             Dec & " rules agents." & Limit & " = "
                                             & Ruled_Text (Ruled_Text'First .. Stop - 1)
                                             & " over the configuration, and a kind's own limit is not"
                                             & " past it; /decision govern " & Dec & " agents." & Limit
                                             & " VALUE rules another, or /decision obsolete " & Dec
                                             & " lets the configuration say it again");
                                 Pres.Report (Screen, Outcome);
                                 return;
                              end if;
                              Pres.Put_Note (Screen, "cli.project.over_ruling",
                                             [Loc.Named ("name", Name & "=" & Given),
                                              Loc.Named ("other", Dec),
                                              Loc.Named ("detail", "agents." & Limit & " = "
                                                         & Ruled_Text (Ruled_Text'First .. Stop - 1))]);
                           end if;
                        end;
                     end if;
                  end;
               end loop;
            exception
               when others =>
                  null;
            end;
         end if;
      end loop;
   end loop;

   --  A root or a deny naming a place the project has not: said, as
   --  a typo grants nothing where it was meant to.
   for Line of Planned.Changed loop
      if Ada.Strings.Fixed.Index (Line, "map.permission.") = Line'First
        and then Ada.Strings.Fixed.Index (Line, " -> ") > 0
      then
         declare
            After   : constant String := Line (Ada.Strings.Fixed.Index (Line, " -> ") + 4 .. Line'Last);
            Missing : constant String :=
              Model_Runner.Framework.Permissions.Missing_Places
                (Ada.Directories.Containing_Directory (S.Root (Store)), After);
         begin
            if Missing /= "" then
               Pres.Put_Note (Screen, "cli.project.places_missing",
                              [Loc.Named ("name", Line (Line'First .. Ada.Strings.Fixed.Index (Line, ":") - 1)),
                               Loc.Named ("detail", Missing)]);
            end if;
         end;
      end if;
   end loop;

   --  A level that gains a capability it did not have -- taken back
   --  to inherit, or turned on -- each named, with what it gets.
   declare
      package Pm renames Model_Runner.Framework.Permissions;
      function Effective_Of (Config : R.Item; Level : String) return Pm.Permission_Set is
         Said_Project : Boolean;
         Of_Project   : constant Pm.Permission_Set := Pm.Level_Of (Config, "project", Said_Project);
         Project      : constant Pm.Permission_Set :=
           (if Said_Project then Of_Project else Pm.Project_Default);
         Said_Own     : Boolean;
         Own          : constant Pm.Permission_Set :=
           (if Level = "project" then Project else Pm.Level_Of (Config, Level, Said_Own));
      begin
         return (if Level = "project" or else not Said_Own then Project else Pm.Intersect (Own, Project));
      end Effective_Of;
      Levels : Names.Vector;
      --  The tasks said to be refused already, by another level: once.
      Refusal_Said : Names.Vector;
   begin
      for Line of Planned.Changed loop
         if Ada.Strings.Fixed.Index (Line, "map.permission.") = Line'First then
            declare
               Rest : constant String := Line (Line'First + 15 .. Line'Last);
               Stop : constant Natural := Ada.Strings.Fixed.Index (Rest, ":");
               Name : constant String := (if Stop = 0 then Rest else Rest (Rest'First .. Stop - 1));
               Dot  : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Name'First + 5);
               Level : constant String :=
                 (if Ada.Strings.Fixed.Index (Name, "project") = Name'First then "project"
                  elsif Ada.Strings.Fixed.Index (Name, "kind.") = Name'First
                    or else Ada.Strings.Fixed.Index (Name, "role.") = Name'First
                  then (if Dot = 0 then Name else Name (Name'First .. Dot - 1))
                  else "");
            begin
               if Level /= "" and then not Levels.Contains (Level) then
                  Levels.Append (Level);
               end if;
            end;
         end if;
      end loop;
      --  The project's gains reach every kind that takes its: said
      --  once, of the project -- and a kind that asked for what the
      --  project now gives, of that kind too.
      if Levels.Contains ("project") then
         for Kind of Tk.Kinds (Store) loop
            declare
               Present : Boolean;
               Own     : constant Pm.Permission_Set := Pm.Level_Of (Planned.After, "kind." & Kind, Present);
               pragma Unreferenced (Own);
            begin
               --  Every kind: one of its own narrows the project's, one
               --  without takes it whole -- either gains or loses with it.
               if not Levels.Contains ("kind." & Kind) then
                  Levels.Append ("kind." & Kind);
               end if;
            end;
         end loop;
      end if;
      for Level of Levels loop
         declare
            Before : constant Pm.Permission_Set := Effective_Of (Planned.Before, Level);
            After  : constant Pm.Permission_Set := Effective_Of (Planned.After, Level);
            Gained : Unbounded_String;
         begin
            for One in Pm.Capability loop
               if After (One).Granted and then not Before (One).Granted then
                  Append (Gained, (if Gained = Null_Unbounded_String then "" else ", ")
                          & Pm.Word (One)
                          & (if Pm.Grant_Text (After (One)) in "" | "granted" then ""
                             else " " & Pm.Grant_Text (After (One))));
               end if;
            end loop;
            if Gained /= Null_Unbounded_String then
               Pres.Put_Note (Screen, "cli.project.level_gains",
                              [Loc.Named ("name", Level), Loc.Named ("detail", To_String (Gained))]);
            end if;
            --  And what it had that it has no more.
            declare
               Lost : Unbounded_String;
            begin
               for One in Pm.Capability loop
                  if Before (One).Granted and then not After (One).Granted then
                     Append (Lost, (if Lost = Null_Unbounded_String then "" else ", ") & Pm.Word (One));
                  end if;
               end loop;
               if Lost /= Null_Unbounded_String then
                  Pres.Put_Note (Screen, "cli.project.level_loses",
                                 [Loc.Named ("name", Level), Loc.Named ("detail", To_String (Lost))]);
               end if;
            end;
            --  Reading or writing the source taken from a kind: its tasks
            --  waiting to be worked would be refused -- named before yes.
            if (Before (Pm.Read_Source).Granted and then not After (Pm.Read_Source).Granted)
              or else (Before (Pm.Write_Source).Granted and then not After (Pm.Write_Source).Granted)
            then
               declare
                  Refused_Now : Unbounded_String;
               begin
                  for Id of Tk.List (Store, "accepted") loop
                     declare
                        Defined : R.Item;
                        Got     : E.Error_Info;
                     begin
                        Tk.Definition (Store, Id, Defined, Got);
                        --  A kind's own; the project's or the role's, every one.
                        if E.Is_Ok (Got)
                          and then ("kind." & R.Get (Defined, "kind") = Level
                                    or else Ada.Strings.Fixed.Index (Level, "kind.") /= Level'First)
                          and then Tk.Ready (Store, Id).Ready
                          and then not Refusal_Said.Contains (Id)
                        then
                           Refusal_Said.Append (Id);
                           Append (Refused_Now, (if Refused_Now = Null_Unbounded_String then "" else ", ") & Id);
                        end if;
                     end;
                  end loop;
                  if Refused_Now /= Null_Unbounded_String then
                     Pres.Put_Note (Screen, "cli.project.level_refuses",
                                    [Loc.Named ("name", Level),
                                     --  Only what it loses: reading, writing, or both.
                                     Loc.Named ("value",
                                                (if (Before (Pm.Read_Source).Granted
                                                     and then not After (Pm.Read_Source).Granted)
                                                   and then (Before (Pm.Write_Source).Granted
                                                             and then not After (Pm.Write_Source).Granted)
                                                 then "read or write the source"
                                                 elsif Before (Pm.Read_Source).Granted
                                                   and then not After (Pm.Read_Source).Granted
                                                 then "read the source"
                                                 else "write the source")),
                                     Loc.Named ("detail", To_String (Refused_Now))]);
                  end if;
               end;
            end if;
         end;
      end loop;
   end;

   --  A create_children grant past the agents' own bound: bounded by
   --  that, and said, not left to be found out.
   declare
      package Pm renames Model_Runner.Framework.Permissions;
      function Bound (Name, Default : String) return Natural is
         Set : constant String := R.Get (Planned.After, Name);
      begin
         return (if Set'Length in 1 .. 6 and then (for all C of Set => C in '0' .. '9')
                 then Natural'Value (Set) else Natural'Value (Default));
      end Bound;
      Max_Children : constant Natural := Bound ("scalar.agents.max_children", "3");
      Max_Depth    : constant Natural := Bound ("scalar.agents.max_depth", "2");
   begin
      for Line of Planned.Changed loop
         if Ada.Strings.Fixed.Index (Line, ".create_children") > 0 then
            declare
               Present : Boolean;
               Name    : constant String :=
                 Line (Line'First + 15 .. Ada.Strings.Fixed.Index (Line, ".create_children") - 1);
               Level   : constant Pm.Permission_Set := Pm.Level_Of (Planned.After, Name, Present);
            begin
               if Present and then Level (Pm.Create_Children).Granted
                 and then Level (Pm.Create_Children).Max_Children = Natural'Last
                 and then Level (Pm.Create_Children).Max_Depth = Natural'Last
               then
                  --  On, with no numbers: what the project grants is
                  --  what it gets, said as that.
                  declare
                     Said_Project : Boolean;
                     Of_Project   : constant Pm.Permission_Set :=
                       Pm.Level_Of (Planned.After, "project", Said_Project);
                     Project      : constant Pm.Grant :=
                       (if Said_Project then Of_Project (Pm.Create_Children)
                        else Pm.Project_Default (Pm.Create_Children));
                  begin
                     if Name /= "project" and then Project.Granted then
                        Pres.Put_Note
                          (Screen, "cli.project.clipped",
                           [Loc.Named ("name", Name),
                            Loc.Named ("detail", "create_children: it gets max_depth="
                                                 & Image (Natural'Min (Project.Max_Depth, Max_Depth))
                                                 & " max_children="
                                                 & Image (Natural'Min (Project.Max_Children, Max_Children)))]);
                     end if;
                  end;
               elsif Present and then Level (Pm.Create_Children).Granted
                 and then (Level (Pm.Create_Children).Max_Children > Max_Children
                           or else Level (Pm.Create_Children).Max_Depth > Max_Depth)
               then
                  --  Only the part past the bound, and a part given no
                  --  number said as that: any, which the bound limits.
                  declare
                     Given    : constant Pm.Grant := Level (Pm.Create_Children);
                     function Said (Count : Natural) return String
                     is (if Count = Natural'Last then "any (none given)" else Image (Count));
                     --  The project's grant, where it binds below the
                     --  agents' bound: that is what holds, said as such.
                     Said_Project : Boolean;
                     Of_Project   : constant Pm.Permission_Set :=
                       Pm.Level_Of (Planned.After, "project", Said_Project);
                     Project      : constant Pm.Grant :=
                       (if Said_Project then Of_Project (Pm.Create_Children)
                        else Pm.Project_Default (Pm.Create_Children));
                     Project_Binds : constant Boolean :=
                       Name /= "project" and then Project.Granted
                       and then Project.Max_Children <= Max_Children and then Project.Max_Depth <= Max_Depth;
                     --  Only what was given: one left unsaid is bounded
                     --  as ever, and no news.
                     Children : constant String :=
                       (if Given.Max_Children > Max_Children and then Given.Max_Children /= Natural'Last
                        then "max_children " & Said (Given.Max_Children) & " past "
                             & Image (Max_Children)
                        else "");
                     Depth    : constant String :=
                       (if Given.Max_Depth > Max_Depth and then Given.Max_Depth /= Natural'Last
                        then "max_depth " & Said (Given.Max_Depth) & " past " & Image (Max_Depth)
                        else "");
                  begin
                     if Project_Binds then
                        --  Said by the clipped note: the project's grant.
                        null;
                     elsif Children /= "" or else Depth /= "" then
                        Pres.Put_Note
                          (Screen, "cli.project.grant_past_bound",
                           [Loc.Named ("name", Name),
                            Loc.Named ("detail", Children & (if Children /= "" and then Depth /= "" then ", "
                                                             else "") & Depth)]);
                     end if;
                  end;
               end if;
            end;
         end if;
      end loop;

      --  The bound raised past what a level grants: that level's
      --  grant, the lower, is what holds there -- said, not lost.
      if (for some Line of Planned.Changed =>
            Ada.Strings.Fixed.Index (Line, "scalar.agents.max_children") = Line'First
            or else Ada.Strings.Fixed.Index (Line, "scalar.agents.max_depth") = Line'First)
      then
         declare
            Levels : Names.Vector;
         begin
            for Index in 1 .. R.Field_Count (Planned.After) loop
               declare
                  Field : constant String := R.Field_Name (Planned.After, Index);
                  At_Cc : constant Natural := Ada.Strings.Fixed.Index (Field, ".create_children");
               begin
                  if Ada.Strings.Fixed.Index (Field, "map.permission.") = Field'First and then At_Cc > 0
                    and then not Levels.Contains (Field (Field'First + 15 .. At_Cc - 1))
                  then
                     Levels.Append (Field (Field'First + 15 .. At_Cc - 1));
                  end if;
               end;
            end loop;
            for Name of Levels loop
               declare
                  Present : Boolean;
                  Level   : constant Pm.Permission_Set := Pm.Level_Of (Planned.After, Name, Present);
                  Given   : constant Pm.Grant := Level (Pm.Create_Children);
                  --  Only the bound this change raised is said.
                  Children_Changed : constant Boolean :=
                    (for some Line of Planned.Changed =>
                       Ada.Strings.Fixed.Index (Line, "scalar.agents.max_children") = Line'First);
                  Depth_Changed    : constant Boolean :=
                    (for some Line of Planned.Changed =>
                       Ada.Strings.Fixed.Index (Line, "scalar.agents.max_depth") = Line'First);
                  Lower_Children   : constant Boolean :=
                    Children_Changed and then Given.Max_Children < Max_Children;
                  Lower_Depth      : constant Boolean := Depth_Changed and then Given.Max_Depth < Max_Depth;
               begin
                  if Present and then Given.Granted and then (Lower_Children or else Lower_Depth) then
                     Pres.Put_Note
                       (Screen, "cli.project.grant_below_bound",
                        [Loc.Named ("name", Name),
                         Loc.Named ("detail",
                                    (if Lower_Children
                                     then "max_children=" & Image (Given.Max_Children) else "")
                                    & (if Lower_Children and then Lower_Depth then " " else "")
                                    & (if Lower_Depth
                                       then "max_depth=" & Image (Given.Max_Depth) else ""))]);
                  end if;
               end;
            end loop;
         end;
      end if;
   end;

   --  What it leaves without a place, said before it is asked: open
   --  tasks in a component the change takes away.
   Known_Before := Tk.Components (Store);
   declare
      Known_After : constant Names.Vector := Tk.Components_Of (Planned.After);
      Listed      : Unbounded_String;
   begin
      for One of Known_After loop
         Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & One);
      end loop;
      for Old of Known_Before loop
         if not Known_After.Contains (Old) then
            declare
               Count : Natural := 0;
            begin
               for Id of Tk.List (Store) loop
                  if Tk.Component_Of_Task (Store, Id) = Old
                    and then Tk.State_Of (Store, Id) not in "complete" | "cancelled" | "rejected"
                  then
                     Count := Count + 1;
                  end if;
               end loop;
               if Count > 0 then
                  Pres.Put_Note
                    (Screen, "cli.project.component_gone",
                     [Loc.Named ("count", Image (Count)), Loc.Named ("name", Old),
                      Loc.Named ("value", To_String (Listed))]);
               end if;
            end;
         end if;
      end loop;
   end;

   --  A lease shorter than the time work may take: said, as such a
   --  lease runs out under a run that is still working.
   declare
      function Number (Name : String) return Natural is
      begin
         return Natural'Value (R.Get (Planned.After, Name));
      exception
         when others =>
            return 0;
      end Number;
      Lease   : constant Natural := Number ("scalar.work.lease");
      Longest : Natural := Number ("scalar.agents.max_seconds");
      Named   : Unbounded_String := To_Unbounded_String ("agents.max_seconds");
   begin
      for Index in 1 .. R.Field_Count (Planned.After) loop
         declare
            Field : constant String := R.Field_Name (Planned.After, Index);
         begin
            if Ada.Strings.Fixed.Index (Field, "scalar.task.max_seconds.") = Field'First
              and then Number (Field) > Longest
            then
               Longest := Number (Field);
               Named := To_Unbounded_String (Field (Field'First + 7 .. Field'Last));
            end if;
         end;
      end loop;
      if Lease > 0 and then Longest > Lease then
         Pres.Put_Note (Screen, "cli.project.lease_short",
                        [Loc.Named ("count", Image (Lease)), Loc.Named ("name", To_String (Named)),
                         Loc.Named ("total", Image (Longest))]);
      end if;
      --  A token budget smaller than an agent's context alone: every
      --  run would fail before it answers.
      for Line of Planned.Changed loop
         declare
            Colon : constant Natural := Ada.Strings.Fixed.Index (Line & ":", ":");
            Field : constant String := Line (Line'First .. Colon - 1);
         begin
            if (Field = "scalar.agents.token_budget"
                or else Ada.Strings.Fixed.Index (Field, "scalar.task.token_budget.") = Field'First)
              and then Number (Field) in 1 .. 2047
            then
               Pres.Put_Note (Screen, "cli.project.budget_small",
                              [Loc.Named ("count", Image (Number (Field)))]);
            end if;
         end;
      end loop;
   end;

   --  Confirmed by confirm=yes among the words, or asked -- but only
   --  on a terminal: a script's next line is not an answer.
   if All_Words.Contains ("confirm=yes") then
      null;
   elsif not Model_Runner.CLI.Choosers.Is_Available (Screen) then
      declare
         Missing : E.Error_Info := E.Make (E.Framework_Input_Missing);
      begin
         E.Add_Text (Missing, "name", "confirm");
         Pres.Report (Screen, Missing);
         Pres.Put_Note (Screen, "cli.next.confirm");
      end;
      return;
   else
      Pres.Put_Message (Screen, "cli.project.reconfigure.confirm", []);
      if not Answered_Yes (Screen) then
         Pres.Put_Message (Screen, "cli.project.reconfigure.kept");
         return;
      end if;
   end if;

   declare
      Change  : S.Transaction;
      Moved   : Names.Vector;
      Became  : Names.Vector;
      --  The tasks that could start before it, to say which it stops.
      Ready_Before : Names.Vector;
      --  And those refused for want of leave, to say which it frees
      --  and which it leaves refused still.
      Refused_Before : Names.Vector;
      Permissions_Changed : constant Boolean :=
        (for some Name of Planned.Changed => Ada.Strings.Fixed.Index (Name, "map.permission.") = Name'First);
   begin
      for Id of Tk.List (Store, "accepted") loop
         if Tk.Ready (Store, Id).Ready then
            Ready_Before.Append (Id);
         elsif Permissions_Changed and then Model_Runner.Framework.Work.Unable_Reason (Store, Id) /= "" then
            Refused_Before.Append (Id);
         end if;
      end loop;
      --  The new revision and the requirements it takes verification
      --  from, committed as one.
      Cf.Stage_Change (Store, Change, Planned, Read);
      if E.Is_Ok (Read) then
         Vf.Reevaluate_Requirements
           (Store, Change, Moved, Read,
            Configuration => Cf.Verification_Fingerprint (Planned.After));
      end if;
      if E.Is_Ok (Read) then
         S.Commit (Store, Change, Read);
      end if;
      if E.Is_Error (Read) then
         Pres.Report (Screen, Read);
         return;
      end if;
      Revision := R.Revision (Planned.After);

      --  Readiness is derived, and worked out from the state as it
      --  now is.
      if E.Is_Ok (Read) then
         Tk.Recompute_Readiness (Store, Change, Became, Read);
      end if;
      if E.Is_Ok (Read) then
         S.Commit (Store, Change, Read);
      end if;
      for Requirement of Moved loop
         Pres.Put_Message
           (Screen, "cli.work.requirement",
            [Loc.Named ("name", Requirement),
             Loc.Named ("value", Nt.State_Of (Store, Nt.Requirement, Requirement))]);
      end loop;
      --  A task it leaves unable to start: said, with why.
      for Id of Ready_Before loop
         declare
            Now : constant Tk.Readiness := Tk.Ready (Store, Id);
         begin
            if not Now.Ready then
               Pres.Put_Note (Screen, "cli.project.no_longer_ready",
                              [Loc.Named ("name", Id),
                               Loc.Named ("detail", (if Now.Reasons.Is_Empty then ""
                                                     else Now.Reasons.First_Element))]);
            end if;
         end;
      end loop;
      --  And one it lets start that could not: said, with the way on.
      for Id of Tk.List (Store, "accepted") loop
         if not Ready_Before.Contains (Id) and then Tk.Ready (Store, Id).Ready then
            Pres.Put_Note (Screen, "cli.task.ready_now", [Loc.Named ("name", Id)]);
         end if;
      end loop;
      --  One refused before and refused still: said, with what it
      --  lacks now, so the change is not taken for its way on.
      for Id of Refused_Before loop
         if not Tk.Ready (Store, Id).Ready
           and then Model_Runner.Framework.Work.Unable_Reason (Store, Id) /= ""
         then
            Pres.Put_Note (Screen, "cli.project.still_refused",
                           [Loc.Named ("name", Id),
                            Loc.Named ("detail", Model_Runner.Framework.Work.Unable_Reason (Store, Id))]);
         end if;
      end loop;
   end;
   --  Components changed: one declared with no roots is told where
   --  its files are said.
   if (for some Name of Planned.Changed =>
         Ada.Strings.Fixed.Index (Name, "map.component.") = Name'First
         or else Ada.Strings.Fixed.Index (Name, "set.components") = Name'First)
   then
      declare
         Known  : constant Names.Vector := Tk.Components (Store);
      begin
         --  Roots within another's: said, with whose the files are.
         for Name of Known loop
            for Other of Known loop
               if Other /= Name then
                  for Inner of Model_Runner.Framework.Repository.Component_Roots (Store, Name) loop
                     for Outer of Model_Runner.Framework.Repository.Component_Roots (Store, Other)
                     loop
                        declare
                           O : constant String :=
                             (if Outer'Length > 1 and then Outer (Outer'Last) = '/'
                              then Outer (Outer'First .. Outer'Last - 1) else Outer);
                           I : constant String :=
                             (if Inner'Length > 1 and then Inner (Inner'Last) = '/'
                              then Inner (Inner'First .. Inner'Last - 1) else Inner);
                        begin
                           --  Strictly within, and new with this change.
                           if I'Length > O'Length + 1
                             and then I (I'First .. I'First + O'Length) = O & "/"
                             and then (for some Line of Planned.Changed =>
                                         Ada.Strings.Fixed.Index
                                           (Line, "map.component." & Name & ":") = Line'First
                                         or else Ada.Strings.Fixed.Index
                                           (Line, "map.component." & Other & ":") = Line'First)
                           then
                              Pres.Put_Note
                                (Screen, "cli.project.component_overlap",
                                 [Loc.Named ("name", Name), Loc.Named ("value", Inner),
                                  Loc.Named ("other", Other), Loc.Named ("detail", Outer)]);
                           end if;
                        end;
                     end loop;
                  end loop;
               end if;
            end loop;
         end loop;
         for Name of Known loop
            if Model_Runner.Framework.Repository.Component_Roots (Store, Name).Is_Empty
              and then R.Get (Planned.After, "input.project_name") /= Name
            then
               Pres.Put_Note (Screen, "cli.project.component_rootless",
                              [Loc.Named ("name", Name)]);
            end if;
         end loop;
         --  Open tasks left in a component the project has no more:
         --  named, with the component their files' place gives them.
         for Id of Tk.List (Store) loop
            declare
               Defined : R.Item;
               Got     : E.Error_Info;
            begin
               Tk.Definition (Store, Id, Defined, Got);
               if E.Is_Ok (Got) and then R.Get (Defined, "component") /= ""
                 and then not Known.Contains (R.Get (Defined, "component"))
                 and then Tk.State_Of (Store, Id) not in "complete" | "cancelled" | "rejected"
               then
                  Pres.Put_Note (Screen, "cli.project.task_strayed",
                                 [Loc.Named ("name", Id),
                                  Loc.Named ("value", R.Get (Defined, "component")),
                                  Loc.Named ("other", (if Known.Is_Empty then "NAME"
                                                       else Known.First_Element))]);
               end if;
            end;
         end loop;
      end;
   end if;

   declare
      Written : Boolean;
   begin
      Model_Runner.Framework.Git.Keep_Policy (Store, Written, Read);
      if E.Is_Error (Read) then
         Pres.Report (Screen, Read);
      end if;
   end;
   Pres.Put_Message
     (Screen, "cli.project.reconfigure.done", [Loc.Named ("count", Image (Revision))]);
end Reconfigure;
