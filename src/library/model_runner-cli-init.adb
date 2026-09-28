with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.CLI.Choosers;
with Model_Runner.Framework;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Consistency;
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
     (Item   : Model_Runner.CLI.Options.Command;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural)
   is
      Directory : constant String :=
        (if T.Is_Empty (Item.Project_Directory) then "."
         else T.To_String (Item.Project_Directory));

      Interactive : constant Boolean := Choosers.Is_Available;

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

      --  Every template on offer, numbered, with why one cannot be used.
      procedure List is
      begin
         for Index in 1 .. Tp.Count (Registry) loop
            declare
               Shown   : constant Tp.Template := Tp.Template_At (Registry, Index);
               Problem : constant E.Error_Info := Tp.Problem (Registry, Index);
               Details : constant String := Tp.Details (Shown);
            begin
               Pres.Put_Message
                 (Screen,
                  (if E.Is_Ok (Problem) then "cli.init.template"
                   else "cli.init.unavailable"),
                  [Loc.Named ("index", T.Image (Long_Long_Integer (Index))),
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

      --  Ask for one input until it is given a value it takes, or the
      --  caller gives up.
      procedure Ask (Declared : Tp.Input_Declaration; Got : out Boolean) is
         Check : E.Error_Info;
         Typed : Unbounded_String;
      begin
         loop
            Choosers.Ask
              (Screen, To_String (Declared.Label),
               To_String (Declared.Description), To_String (Declared.Choices),
               To_String (Declared.Default), Typed, Got);
            if not Got then
               return;
            end if;
            Cf.Check_Input (Declared, To_String (Typed), Check);
            if E.Is_Ok (Check) then
               Given.Include (To_String (Declared.Id), To_String (Typed));
               return;
            end if;
            Pres.Report (Screen, Check);
         end loop;
      end Ask;

      --  The templates to choose from, the ones that cannot be used shown
      --  with why and not taken.
      function Offered return Choosers.Choice_List is
         Result : Choosers.Choice_List;
      begin
         for Index in 1 .. Tp.Count (Registry) loop
            declare
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
                 (Tp.Id (Tp.Template_At (Registry, Picked)));
            end if;
         end;
         if Chosen = Null_Unbounded_String then
            Pres.Put_Note (Screen, "cli.init.cancelled");
            Status := E.Exit_Cancelled;
            return;
         end if;
      end if;

      Tp.Compose (Registry, To_String (Chosen), Composed, Outcome);
      if E.Is_Error (Outcome) then
         Fail (Outcome);
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

         if Outcome.Code /= E.Framework_Input_Missing or else not Interactive
         then
            Fail (Outcome);
            return;
         end if;

         for Missing of Planned.Missing loop
            for Index in 1 .. Tp.Input_Count (Composed) loop
               declare
                  Declared : constant Tp.Input_Declaration :=
                    Tp.Input_At (Composed, Index);
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

      --  The plan, as an answer: what the project will be.
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

      --  Confirmed where the policy wants it: asked at a terminal, and
      --  otherwise given as confirm=yes or missing, never assumed.
      if R.Get (Planned.Configuration, "scalar.init.confirm") in "yes" | "true" | "required"
        and then not Confirmed
      then
         if not Interactive then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "confirm");
            Fail (Outcome);
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
         Fail (Outcome);
         return;
      end if;

      for Made of Done.Made_Directories loop
         Pres.Put_Note (Screen, "cli.init.made", [Loc.Named ("path", Made)]);
      end loop;
      for Made of Done.Written_Files loop
         Pres.Put_Note (Screen, "cli.init.made", [Loc.Named ("path", Made)]);
      end loop;
      for Kept of Done.Kept_Files loop
         Pres.Put_Note (Screen, "cli.init.kept", [Loc.Named ("path", Kept)]);
      end loop;

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

      --  The result checked as any project's state is: what was made holds
      --  together, or is said not to.
      declare
         package Cs renames Model_Runner.Framework.Consistency;
         Found : constant Cs.Finding_List := Cs.Check (Store);
      begin
         if Cs.Length (Found) > 0 then
            for Index in 1 .. Cs.Length (Found) loop
               Pres.Put_Message
                 (Screen, "cli.task.item",
                  [Loc.Named ("name", To_String (Cs.Element (Found, Index).Subject)),
                   Loc.Named ("value", Cs.Kind_Word (Cs.Element (Found, Index).Kind)),
                   Loc.Named ("detail", To_String (Cs.Element (Found, Index).Detail))]);
            end loop;
            Pres.Put_Message
              (Screen, "cli.project.consistency",
               [Loc.Named ("count", T.Image (Long_Long_Integer (Cs.Length (Found))))]);
            Status := E.Exit_Input_Output;
         end if;
      end;
      S.Close (Store);
   end Run;

end Model_Runner.CLI.Init;
