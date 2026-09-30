with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.CLI.Choosers;
with Model_Runner.CLI.Options;
with Model_Runner.Framework;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Verification;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Templates;
with Model_Runner.Localization;
with Model_Runner.Platform;
with Model_Runner.Text;

package body Model_Runner.CLI.Init is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;
   package Cf renames Model_Runner.Framework.Configurations;
   package Loc renames Model_Runner.Localization;
   package Pres renames Model_Runner.Presentation;
   package R renames Model_Runner.Framework.Records;
   package S renames Model_Runner.Framework.Stores;
   package T renames Model_Runner.Text;
   package Tp renames Model_Runner.Framework.Templates;

   ---------
   -- Run --
   ---------

   procedure Run
     (Item   : Model_Runner.CLI.Project_Requests.Request;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural)
   is
      Directory : constant String :=
        (if T.Is_Empty (Item.Project_Directory) then "."
         else T.To_String (Item.Project_Directory));

      Interactive : constant Boolean := Choosers.Is_Available (Screen);

      Places   : Model_Runner.Framework.Name_Lists.Vector;
      Registry : Tp.Registry;
      Chosen   : Unbounded_String :=
        To_Unbounded_String (T.To_String (Item.Template_Name));
      Composed : Tp.Composition;
      Given    : Cf.Value_Maps.Map;
      Confirmed : Boolean := False;
      Planned  : Cf.Plan;
      Done     : Cf.Outcome;
      Store    : S.Store;
      Outcome  : E.Error_Info;

      procedure Fail (Condition : E.Error_Info) is
      begin
         Pres.Report (Screen, Condition);
         Status := E.Exit_Status (Condition);
      end Fail;

      --  The templates a project may start from, by their place in the
      --  registry: a part only other templates include is not one.
      function Kinds return Model_Runner.Framework.Name_Lists.Vector is
         Result : Model_Runner.Framework.Name_Lists.Vector;
      begin
         for Index in 1 .. Tp.Count (Registry) loop
            if Tp.Is_Standalone (Tp.Template_At (Registry, Index)) then
               Result.Append (T.Image (Long_Long_Integer (Index)));
            end if;
         end loop;
         return Result;
      end Kinds;

      --  Every template on offer, numbered, with why one cannot be used.
      procedure List is
         Shown_Number : Natural := 0;
      begin
         for Place of Kinds loop
            declare
               Index   : constant Positive := Positive'Value (Place);
               Shown   : constant Tp.Template := Tp.Template_At (Registry, Index);
               Problem : constant E.Error_Info := Tp.Problem (Registry, Index);
               Details : constant String := Tp.Details (Shown);
            begin
               Shown_Number := Shown_Number + 1;
               Pres.Put_Message
                 (Screen,
                  (if E.Is_Ok (Problem) then "cli.init.template"
                   else "cli.init.unavailable"),
                  [Loc.Named ("index", T.Image (Long_Long_Integer (Shown_Number))),
                   Loc.Named ("name", Tp.Id (Shown)),
                   Loc.Named ("value", Tp.Display_Name (Shown)),
                   Loc.Named ("detail",
                              (if Details = "" then Tp.Description (Shown)
                               else Details))]);

               --  Why it cannot be used, said as the warning it is.
               if E.Is_Error (Problem) then
                  declare
                     Said : E.Error_Info := Problem;
                  begin
                     Said.Severity := E.Severity_Warning;
                     Pres.Report (Screen, Said);
                  end;
               end if;
            end;
         end loop;
      end List;

      --  Facts to record; a template's that discovery answered otherwise
      --  is shown as discovery found it.
      procedure Show_Facts (Facts : Cf.Value_Maps.Map; Declared : Boolean) is
      begin
         for Position in Facts.Iterate loop
            if not Declared
              or else not Planned.Discovered_Facts.Contains
                            (Cf.Value_Maps.Key (Position))
            then
               Pres.Put_Message
              (Screen, "cli.init.fact",
                  [Loc.Named ("name", Cf.Value_Maps.Key (Position)),
                   Loc.Named ("value", Cf.Value_Maps.Element (Position))]);
            end if;
         end loop;
      end Show_Facts;

      --  What an input is, what it takes and why its default did not do.
      function Input_Detail (Declared : Tp.Input_Declaration; From : Cf.Plan) return String is
         Label  : constant String := To_String (Declared.Label);
         About  : constant String := To_String (Declared.Description);
         Choice : constant String := To_String (Declared.Choices);
         Id     : constant String := To_String (Declared.Id);
      begin
         return (if Label /= "" then Label else Id)
           & (if About /= "" then ": " & About else "")
           & (if Choice /= "" then "; one of " & Choice else "")
           & (if From.Missing_Why.Contains (Id) then "; " & From.Missing_Why (Id) else "");
      end Input_Detail;

      --  Ask for one input until it is given a value it takes, or the
      --  caller gives up.
      procedure Ask (Declared : Tp.Input_Declaration; Got : out Boolean) is
         Check : E.Error_Info;
         Typed : Unbounded_String;
         --  Why its default did not do, said the first time only: a value
         --  typed and refused is refused with its own reason.
         First : Boolean := True;
      begin
         loop
            Choosers.Ask
              (Screen, To_String (Declared.Label),
               To_String (Declared.Description)
               & (if First and then Planned.Missing_Why.Contains (To_String (Declared.Id))
                  then "; " & Planned.Missing_Why (To_String (Declared.Id)) else ""),
               To_String (Declared.Choices),
               (if Ada.Strings.Fixed.Index (To_String (Declared.Default), "${") > 0 then ""
                else To_String (Declared.Default)),
               Typed, Got, Secret => Declared.Secret, Required => Declared.Required);
            if not Got then
               return;
            end if;
            Cf.Check_Input (Declared, To_String (Typed), Check);
            if E.Is_Ok (Check) then
               Given.Include (To_String (Declared.Id), To_String (Typed));
               return;
            end if;
            Pres.Report (Screen, Check);
            First := False;
         end loop;
      end Ask;

      --  The templates to choose from, the ones that cannot be used shown
      --  with why and not taken.
      function Offered return Choosers.Choice_List is
         Result : Choosers.Choice_List;
      begin
         for Place of Kinds loop
            declare
               Index   : constant Positive := Positive'Value (Place);
               Shown   : constant Tp.Template := Tp.Template_At (Registry, Index);
               Problem : constant E.Error_Info := Tp.Problem (Registry, Index);
            begin
               Choosers.Append
                 (Result,
                  (Label      => To_Unbounded_String
                                   (Tp.Display_Name (Shown) & "  ("
                                    & Tp.Id (Shown) & ")"),
                   Tag        => Null_Unbounded_String,
                   Details    => To_Unbounded_String
                                   (Tp.Description (Shown) & ASCII.LF
                                    & Tp.Details (Shown) & ASCII.LF
                                    & (if E.Is_Ok (Problem) then ""
                                       else Pres.Message_Value
                                              (Screen, "cli.init.cannot"))),
                   Selectable => E.Is_Ok (Problem)));
            end;
         end loop;
         return Result;
      end Offered;

   begin
      Status := E.Exit_Success;

      --  A project that has its state already is changed, not started:
      --  said before anything is asked or planned.
      if S.Is_Initialized (Directory) then
         Outcome := E.Make (E.Framework_Already_Initialized);
         E.Add_Text (Outcome, "path", Ada.Directories.Full_Name (Directory), E.Param_Path);
         Fail (Outcome);
         Pres.Put_Note (Screen, "cli.next.initialized");
         if not T.Is_Empty (Item.Project_Directory) then
            Pres.Put_Note (Screen, "cli.next.in_directory", [Loc.Named ("path", Directory)]);
         end if;
         return;
      end if;

      if Model_Runner.Platform.User_Templates_Directory /= "" then
         Places.Append (Model_Runner.Platform.User_Templates_Directory);
      end if;
      Places.Append (Model_Runner.Platform.Installed_Templates_Directory);
      Tp.Discover (Places, Registry);

      --  No template named: a terminal chooses one from the list, and
      --  anything else is shown the list and told it must name one.
      if Chosen = Null_Unbounded_String then
         if Tp.Count (Registry) = 0 then
            Pres.Put_Note
              (Screen, "cli.init.none",
               [Loc.Named
                  ("path", Model_Runner.Platform.Installed_Templates_Directory)]);
            Outcome := E.Make (E.Framework_Template_Not_Found);
            E.Add_Text (Outcome, "name", "");
            Fail (Outcome);
            return;
         end if;

         if not Interactive then
            Pres.Put_Message (Screen, "cli.init.header");
            List;
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "template");
            Fail (Outcome);
            return;
         end if;

         declare
            Picked : constant Natural :=
              Choosers.Choose (Screen, "cli.init.choose", Offered);
         begin
            if Picked > 0 then
               Chosen := To_Unbounded_String
                 (Tp.Id (Tp.Template_At (Registry, Positive'Value (Kinds.Element (Picked)))));
            end if;
         end;
         if Chosen = Null_Unbounded_String then
            Pres.Put_Note (Screen, "cli.init.cancelled");
            Status := E.Exit_Cancelled;
            return;
         end if;
      end if;

      --  A number is the template of that number in the list.
      declare
         Said : constant String := To_String (Chosen);
      begin
         if Said'Length in 1 .. 4 and then (for all C of Said => C in '0' .. '9')
           and then Natural'Value (Said) in 1 .. Natural (Kinds.Length)
         then
            Chosen := To_Unbounded_String
              (Tp.Id (Tp.Template_At (Registry, Positive'Value (Kinds.Element (Natural'Value (Said))))));
         end if;
      end;

      --  A part other templates include is no project of its own.
      for Index in 1 .. Tp.Count (Registry) loop
         if Tp.Id (Tp.Template_At (Registry, Index)) = To_String (Chosen)
           and then not Tp.Is_Standalone (Tp.Template_At (Registry, Index))
         then
            Pres.Put_Message (Screen, "cli.init.header");
            List;
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "template");
            E.Add_Text (Outcome, "value", To_String (Chosen));
            E.Add_Text (Outcome, "detail", "it is a part other templates include, not a kind of project");
            Fail (Outcome);
            return;
         end if;
      end loop;

      Tp.Compose (Registry, To_String (Chosen), Composed, Outcome);
      if E.Is_Error (Outcome) then
         Fail (Outcome);

         --  One not installed: those that are.
         if E."=" (Outcome.Code, E.Framework_Template_Not_Found) then
            Pres.Put_Message (Screen, "cli.init.header");
            List;
         end if;
         return;
      end if;

      for Index in 1 .. Item.Input_Count loop
         declare
            Pair : constant String := T.To_String (Item.Inputs (Index));
         begin
            for Cut in Pair'Range loop
               if Pair (Cut) = '=' then
                  Given.Include
                    (Pair (Pair'First .. Cut - 1), Pair (Cut + 1 .. Pair'Last));
                  exit;
               end if;
            end loop;
         end;
      end loop;

      --  confirm=yes is the answer to the policy's question, given ahead;
      --  no template asks for it as an input.
      Confirmed := Given.Contains ("confirm") and then Given ("confirm") in "yes" | "true";
      Given.Exclude ("confirm");

      --  What is known is not asked for: given, found in the project or
      --  defaulted. A terminal is asked for the rest, one at a time.
      loop
         Cf.Prepare (Composed, Directory, Given, Planned, Outcome);
         exit when E.Is_Ok (Outcome);

         --  A program reading the answer is given an entry for each input
         --  missing, each named in a field of its own.
         if Outcome.Code = E.Framework_Input_Missing and then not Interactive
           and then Pres.Is_Structured (Screen) and then not Planned.Missing.Is_Empty
         then
            for Missing of Planned.Missing loop
               declare
                  One : E.Error_Info := E.Make (E.Framework_Input_Missing);
               begin
                  E.Add_Text (One, "name", Missing);
                  --  What it is and how it is given, as plain output says.
                  for Index in 1 .. Tp.Input_Count (Composed) loop
                     declare
                        Declared : constant Tp.Input_Declaration :=
                          Cf.Resolved (Tp.Input_At (Composed, Index), Directory);
                     begin
                        if To_String (Declared.Id) = Missing then
                           E.Add_Text (One, "detail", Input_Detail (Declared, Planned));
                           E.Add_Text (One, "value", "--set " & Missing & "=...");
                        end if;
                     end;
                  end loop;
                  Pres.Report (Screen, One);
               end;
            end loop;
            Status := E.Exit_Status (Outcome);
            return;
         end if;

         if Outcome.Code /= E.Framework_Input_Missing or else not Interactive
         then
            Fail (Outcome);

            --  Each input missing, as it is given, what it is, and why a
            --  default did not do.
            if Outcome.Code = E.Framework_Input_Missing then
               for Missing of Planned.Missing loop
                  for Index in 1 .. Tp.Input_Count (Composed) loop
                     declare
                        Declared : constant Tp.Input_Declaration :=
                          Cf.Resolved (Tp.Input_At (Composed, Index), Directory);
                     begin
                        if To_String (Declared.Id) = Missing then
                           Pres.Put_Note
                             (Screen, "cli.input.needed",
                              [Loc.Named ("name", Missing),
                               Loc.Named ("detail", Input_Detail (Declared, Planned))]);
                        end if;
                     end;
                  end loop;
               end loop;

               --  And the confirmation it will want, with the rest, not
               --  asked for once they are given.
               if not Confirmed
                 and then (for some Index in 1 .. Tp.Setting_Count (Composed) =>
                             Tp."=" (Tp.Setting_At (Composed, Index).Kind, Tp.Scalar_Setting)
                             and then To_String (Tp.Setting_At (Composed, Index).Key) = "init.confirm"
                             and then To_String (Tp.Setting_At (Composed, Index).Value)
                                        in "yes" | "true" | "required")
               then
                  Pres.Put_Note (Screen, "cli.next.confirm_init_also");
               end if;
            end if;
            return;
         end if;

         for Missing of Planned.Missing loop
            for Index in 1 .. Tp.Input_Count (Composed) loop
               declare
                  Declared : constant Tp.Input_Declaration :=
                    Cf.Resolved (Tp.Input_At (Composed, Index), Directory);
                  Got      : Boolean;
               begin
                  if To_String (Declared.Id) = Missing then
                     Ask (Declared, Got);
                     if not Got then
                        Pres.Put_Note (Screen, "cli.init.cancelled");
                        Status := E.Exit_Cancelled;
                        return;
                     end if;
                  end if;
               end;
            end loop;
         end loop;
      end loop;

      --  The plan, as an answer: what the project will be -- not shown
      --  to one who asked for quiet.
      if Model_Runner.CLI.Options."/=" (Item.Level, Model_Runner.CLI.Options.Quiet) then
         Pres.Put_Message
           (Screen, "cli.init.plan",
            [Loc.Named ("name", Tp.Id (Tp.Root (Composed))),
             Loc.Named ("version", Tp.Version (Tp.Root (Composed))),
             Loc.Named ("path", Directory)]);
         for Made of Planned.Directories loop
            Pres.Put_Message (Screen, "cli.init.directory", [Loc.Named ("path", Made)]);
         end loop;
         for Position in Planned.Files.Iterate loop
            Pres.Put_Message
              (Screen, "cli.init.file",
               [Loc.Named ("path", Cf.Value_Maps.Key (Position))]);
         end loop;
         Show_Facts (Planned.Template_Facts, Declared => True);
         Show_Facts (Planned.Discovered_Facts, Declared => False);
      end if;

      --  Confirmed where the policy wants it: asked at a terminal, and
      --  otherwise given as confirm=yes or missing, never assumed.
      if R.Get (Planned.Configuration, "scalar.init.confirm") in "yes" | "true" | "required"
        and then not Confirmed
      then
         if not Interactive then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "confirm");
            Fail (Outcome);
            Pres.Put_Note (Screen, "cli.next.confirm_init");
            return;
         end if;
         declare
            Answers : Choosers.Choice_List;
         begin
            Choosers.Append
              (Answers, (Label      => To_Unbounded_String
                                         (Pres.Message_Value (Screen, "cli.init.confirm.yes")),
                         Tag        => Null_Unbounded_String,
                         Details    => Null_Unbounded_String,
                         Selectable => True));
            Choosers.Append
              (Answers, (Label      => To_Unbounded_String
                                         (Pres.Message_Value (Screen, "cli.init.confirm.no")),
                         Tag        => Null_Unbounded_String,
                         Details    => Null_Unbounded_String,
                         Selectable => True));
            if Choosers.Choose (Screen, "cli.init.confirm", Answers) /= 1 then
               Pres.Put_Note (Screen, "cli.init.cancelled");
               Status := E.Exit_Cancelled;
               return;
            end if;
         end;
      end if;

      Cf.Initialize (Store, Directory, Planned, Done, Outcome);
      if E.Is_Error (Outcome) then
         --  What the check of the result found, when that undid it.
         for Line of Done.Findings loop
            Pres.Put_Note (Screen, "cli.task.field",
                           [Loc.Named ("name", "found"), Loc.Named ("value", Line)]);
         end loop;
         Fail (Outcome);
         return;
      end if;

      --  What was made, where the plan did not already list it: asked for
      --  in detail only.
      if Model_Runner.CLI.Options."=" (Item.Level, Model_Runner.CLI.Options.Verbose) then
         for Made of Done.Made_Directories loop
            Pres.Put_Note (Screen, "cli.init.made", [Loc.Named ("path", Made)]);
         end loop;
         for Made of Done.Written_Files loop
            Pres.Put_Note (Screen, "cli.init.made", [Loc.Named ("path", Made)]);
         end loop;
      end if;
      --  What the check of the result found and left standing.
      for Line of Done.Findings loop
         Pres.Put_Note (Screen, "cli.task.field",
                        [Loc.Named ("name", "found"), Loc.Named ("value", Line)]);
      end loop;
      for Kept of Done.Kept_Files loop
         Pres.Put_Note (Screen, "cli.init.kept", [Loc.Named ("path", Kept)]);
      end loop;

      --  A check the project's own policy will not run: said now, not at
      --  the first verification that blocks on it.
      declare
         Rules : constant Model_Runner.Framework.Execution.Policy :=
           Model_Runner.Framework.Execution.Policy_Of (Store);
      begin
         for Index in 1 .. R.Field_Count (Planned.Configuration) loop
            declare
               Name : constant String := R.Field_Name (Planned.Configuration, Index);
            begin
               if Ada.Strings.Fixed.Index (Name, "profile.") = Name'First then
                  --  Each check as verification reads it, not the text
                  --  it is written in.
                  declare
                     package Vf renames Model_Runner.Framework.Verification;
                     Checks : constant Vf.Check_List :=
                       Vf.Parse_Profile (R.Get (Planned.Configuration, Name));
                  begin
                     for Index in 1 .. Vf.Length (Checks) loop
                        declare
                           One     : constant Vf.Check := Vf.Element (Checks, Index);
                           Command : constant String := To_String (One.Command);
                           Why     : constant String :=
                             (if Command = "" then ""
                              else Model_Runner.Framework.Execution.Refusal (Rules, Command));
                        begin
                           if Why /= "" then
                              Pres.Put_Note
                                (Screen, "cli.init.check_refused",
                                 [Loc.Named ("name", To_String (One.Label)),
                                  Loc.Named ("value", Command), Loc.Named ("detail", Why)]);
                           end if;
                        end;
                     end loop;
                  end;
               end if;
            end;
         end loop;
      end;

      --  What of the state goes into the repository, as the policy says.
      declare
         Written : Boolean;
      begin
         Model_Runner.Framework.Git.Keep_Policy (Store, Written, Outcome);
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
         end if;
      end;

      Pres.Put_Message
        (Screen, "cli.init.done",
         [Loc.Named ("name", S.Project_Name (Store)),
          Loc.Named ("path", S.Root (Store)),
          Loc.Named
            ("detail",
             R.Get (Planned.Configuration, "configuration_fingerprint"))]);
      --  In a session, the steps after it are the session's commands, which
      --  work where the session was started: not offered for elsewhere.
      if not (Pres.In_Session (Screen) and then not T.Is_Empty (Item.Project_Directory)) then
         Pres.Put_Note (Screen, "cli.next.init");
      end if;
      --  Started elsewhere: each of those in the directory it names.
      if not T.Is_Empty (Item.Project_Directory) then
         Pres.Put_Note
           (Screen,
            (if Pres.In_Session (Screen) then "cli.next.in_directory_session"
             else "cli.next.in_directory"),
            [Loc.Named ("path", Directory)]);
      end if;

      S.Close (Store);
   end Run;

end Model_Runner.CLI.Init;
