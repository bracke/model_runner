with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit.Fs;

with Model_Runner.Errors;
with Model_Runner.CLI.Choosers;
with Model_Runner.CLI.Options;
with Model_Runner.Framework;
with Model_Runner.Framework.Bootstrap;
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
      Allowing  : Boolean := False;
      Changing  : Boolean := False;
      Fixes     : Cf.Value_Maps.Map;
      Planned  : Cf.Plan;
      Done     : Cf.Outcome;
      Store    : S.Store;
      Outcome  : E.Error_Info;

      --  Whether the directory holds anything of its own already -- more
      --  than what a version control system keeps.
      function Has_Content return Boolean is
         use Ada.Directories;
         Search : Search_Type;
         Found  : Directory_Entry_Type;
         Any    : Boolean := False;
      begin
         if not Exists (Directory) then
            return False;
         end if;
         Start_Search (Search, Directory, "");
         while More_Entries (Search) and then not Any loop
            Get_Next_Entry (Search, Found);
            Any := Simple_Name (Found) not in "." | ".." | ".git" | ".hg" | ".svn";
         end loop;
         End_Search (Search);
         return Any;
      exception
         when others =>
            return False;
      end Has_Content;

      procedure Fail (Condition : E.Error_Info) is
      begin
         Pres.Report (Screen, Condition);
         Status := E.Exit_Status (Condition);
      end Fail;

      --  The templates a project may start from, by their place in the
      --  registry: a part only other templates include is not one.
      --  In a directory that already holds a project, the templates that
      --  take one as it is come first, so the one Enter takes writes
      --  nothing over it.
      --  The templates in the order offered: where the directory has an
      --  Alire manifest, the Ada ones first -- the application's where it
      --  names executables; where it holds anything else, the one for any
      --  language; in an empty one, as installed.
      function Kinds return Model_Runner.Framework.Name_Lists.Vector is
         Result : Model_Runner.Framework.Name_Lists.Vector;
         Manifest : constant String := Hostkit.Fs.Join (Directory, "alire.toml");
         Alire    : constant Boolean := Ada.Directories.Exists (Manifest);

         function Executables return Boolean is
            File : Ada.Text_IO.File_Type;
            Said : Boolean := False;
         begin
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Manifest);
            while not Ada.Text_IO.End_Of_File (File) and then not Said loop
               Said := Ada.Strings.Fixed.Index (Ada.Text_IO.Get_Line (File), "executables") = 1;
            end loop;
            Ada.Text_IO.Close (File);
            return Said;
         exception
            when others =>
               if Ada.Text_IO.Is_Open (File) then
                  Ada.Text_IO.Close (File);
               end if;
               return False;
         end Executables;
         Runs : constant Boolean := Alire and then Executables;

         function Rank (Index : Positive) return Natural is
            Category : constant String := Tp.Category (Tp.Template_At (Registry, Index));
         begin
            if Alire then
               return (if Category = (if Runs then "application" else "library") then 0
                       elsif Category in "application" | "library" then 1
                       else 2);
            elsif Has_Content then
               return (if Category = "any" then 0 else 1);
            end if;
            return 0;
         end Rank;
      begin
         for Pass in 0 .. 2 loop
            for Index in 1 .. Tp.Count (Registry) loop
               if Tp.Is_Standalone (Tp.Template_At (Registry, Index)) and then Rank (Index) = Pass then
                  Result.Append (T.Image (Long_Long_Integer (Index)));
               end if;
            end loop;
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
            begin
               Shown_Number := Shown_Number + 1;
               Pres.Put_Message
                 (Screen,
                  (if E.Is_Ok (Problem) then "cli.init.template"
                   else "cli.init.unavailable"),
                  [Loc.Named ("index", T.Image (Long_Long_Integer (Shown_Number))),
                   Loc.Named ("name", Tp.Id (Shown)),
                   Loc.Named ("value", Tp.Display_Name (Shown)),
                   --  What it is for, in its own words: its tags are
                   --  words to find it by, not a description.
                   Loc.Named ("detail", Tp.Description (Shown))]);

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
                                    & (if Tp.Details (Shown) = "" then ""
                                       else "found by: " & Tp.Details (Shown) & ASCII.LF)
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
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "template");
            E.Add_Text (Outcome, "value", To_String (Chosen));
            E.Add_Text (Outcome, "detail", "it is a part other templates include, not a kind of project");
            Fail (Outcome);
            Pres.Put_Message (Screen, "cli.init.header");
            List;
            return;
         end if;
      end loop;

      Tp.Compose (Registry, To_String (Chosen), Composed, Outcome);
      if E.Is_Error (Outcome) then
         --  A name a letter or two from one there is: that one, offered.
         if E."=" (Outcome.Code, E.Framework_Template_Not_Found) then
            declare
               Ids  : Model_Runner.Framework.Name_Lists.Vector;
            begin
               for Place of Kinds loop
                  Ids.Append (Tp.Id (Tp.Template_At (Registry, Positive'Value (Place))));
               end loop;
               declare
                  Near : constant String := Model_Runner.Framework.Nearest (To_String (Chosen), Ids);
               begin
                  if Near /= "" then
                     Outcome := E.Make (E.Framework_Template_Not_Found);
                     E.Add_Text (Outcome, "name", To_String (Chosen) & "; did you mean " & Near & "?");
                  end if;
               end;
            end;
         end if;
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

      --  Planned, shown and confirmed -- and planned again where an input
      --  is changed at the confirmation.
      Planning :
      loop
         Changing := False;
         Fixes.Clear;
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
                              E.Add_Text (One, "value", Missing & "=...");
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

         --  The plan and what it will not be able to do, worked out before
         --  anything is written: shown, and -- where it writes into a
         --  directory that holds a project already, where a check it names
         --  will be refused, or where the template wants it -- asked about
         --  with the plan above the question.
         declare
            Plan_Text : Unbounded_String;
            Writes_In : Boolean := False;

            --  The plan as the question shows it: short enough to be read
            --  above it, each part a line.
            Inputs_Said : Unbounded_String;
            Files_Said  : Unbounded_String;
            Dirs_Said   : Unbounded_String;
            Kept_Said   : Unbounded_String;
            Warned      : Unbounded_String;

            --  What an input is for, as its template says.
            function Described (Id : String) return String is
            begin
               for Index in 1 .. Tp.Input_Count (Composed) loop
                  declare
                     Declared : constant Tp.Input_Declaration := Tp.Input_At (Composed, Index);
                  begin
                     if To_String (Declared.Id) = Id and then Length (Declared.Description) > 0 then
                        return "  -- " & To_String (Declared.Description);
                     end if;
                  end;
               end loop;
               return "";
            end Described;

            --  The crate a manifest names, or "".
            function Crate_Named (Path : String) return String is
               File  : Ada.Text_IO.File_Type;
               Found : Unbounded_String;
            begin
               Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
               while not Ada.Text_IO.End_Of_File (File) and then Found = Null_Unbounded_String loop
                  declare
                     Bare  : constant String :=
                       Ada.Strings.Fixed.Trim (Ada.Text_IO.Get_Line (File), Ada.Strings.Both);
                     First : constant Natural := Ada.Strings.Fixed.Index (Bare, [1 => '"']);
                     Last  : constant Natural :=
                       Ada.Strings.Fixed.Index (Bare, [1 => '"'], Ada.Strings.Backward);
                  begin
                     if Bare'Length > 4 and then Bare (Bare'First .. Bare'First + 3) = "name"
                       and then First > 0 and then Last > First
                     then
                        Found := To_Unbounded_String (Bare (First + 1 .. Last - 1));
                     end if;
                  end;
               end loop;
               Ada.Text_IO.Close (File);
               return To_String (Found);
            exception
               when others =>
                  if Ada.Text_IO.Is_Open (File) then
                     Ada.Text_IO.Close (File);
                  end if;
                  return "";
            end Crate_Named;
            Refused   : Model_Runner.Framework.Name_Lists.Vector;
            Rules     : constant Model_Runner.Framework.Execution.Policy :=
              Model_Runner.Framework.Execution.Policy_From (Planned.Configuration);

            --  Asked about at a terminal, the plan is the question's: shown
            --  in it, and written out once, when it is taken -- not again
            --  for each round of changing an input.
            Asking : constant Boolean := Interactive and then not Confirmed;

            procedure Say (Key : String; Arguments : Loc.Argument_List) is
               Line : constant String := Pres.Next_Step_Value (Screen, Key, Arguments);
            begin
               Append (Plan_Text, Line & ASCII.LF);
               if Model_Runner.CLI.Options."/=" (Item.Level, Model_Runner.CLI.Options.Quiet)
                 and then not Asking
               then
                  Pres.Put_Message (Screen, Key, Arguments);
               end if;
            end Say;
         begin
            Say ("cli.init.plan",
                 [Loc.Named ("name", Tp.Id (Tp.Root (Composed))),
                  Loc.Named ("version", Tp.Version (Tp.Root (Composed))),
                  Loc.Named ("path", Ada.Directories.Full_Name (Directory))]);
            --  Each input's value, however it came -- given, found or its
            --  default -- so one never asked for is still seen.
            for Position in Planned.Inputs.Iterate loop
               declare
                  Id     : constant String := Cf.Value_Maps.Key (Position);
                  Secret : Boolean := False;
               begin
                  --  A secret is not shown, not even here.
                  for Index in 1 .. Tp.Input_Count (Composed) loop
                     if To_String (Tp.Input_At (Composed, Index).Id) = Id then
                        Secret := Tp.Input_At (Composed, Index).Secret;
                     end if;
                  end loop;
                  Say ("cli.init.input",
                       [Loc.Named ("name", Id),
                        Loc.Named ("value", (if Secret then Pres.Message_Value (Screen, "cli.init.secret")
                                             else Cf.Value_Maps.Element (Position))),
                        Loc.Named ("detail", Described (Id))]);
                  Append (Inputs_Said, (if Inputs_Said = Null_Unbounded_String then "" else ", ")
                                       & Id & " = "
                                       & (if Secret then Pres.Message_Value (Screen, "cli.init.secret")
                                          else Cf.Value_Maps.Element (Position)));
               end;
            end loop;
            for Made of Planned.Directories loop
               Say ("cli.init.directory", [Loc.Named ("path", Made)]);
            end loop;
            for Made of Planned.Directories loop
               Append (Dirs_Said, (if Dirs_Said = Null_Unbounded_String then "" else ", ") & Made);
            end loop;
            for Position in Planned.Files.Iterate loop
               declare
                  Path : constant String := Cf.Value_Maps.Key (Position);
                  There : constant Boolean :=
                    Ada.Directories.Exists (Hostkit.Fs.Join (Directory, Path));
               begin
                  Writes_In := Writes_In or else not There;
                  Say ((if There then "cli.init.file_kept" else "cli.init.file"),
                       [Loc.Named ("path", Path)]);
                  if There then
                     Append (Kept_Said, (if Kept_Said = Null_Unbounded_String then "" else ", ") & Path);
                     --  A manifest kept that names another crate than the
                     --  inputs: what the template writes beside it assumes
                     --  its own, and would not build against this one.
                     if Ada.Directories.Simple_Name (Path) = "alire.toml"
                       and then Planned.Inputs.Contains ("project_name")
                       and then Crate_Named (Hostkit.Fs.Join (Directory, Path)) /= ""
                       and then Crate_Named (Hostkit.Fs.Join (Directory, Path))
                                /= Planned.Inputs ("project_name")
                     then
                        Say ("cli.init.kept_differs",
                             [Loc.Named ("path", Path),
                              Loc.Named ("name", Crate_Named (Hostkit.Fs.Join (Directory, Path))),
                              Loc.Named ("value", Planned.Inputs ("project_name"))]);
                        Append (Warned, Pres.Next_Step_Value
                                          (Screen, "cli.init.kept_differs",
                                           [Loc.Named ("path", Path),
                                            Loc.Named ("name", Crate_Named (Hostkit.Fs.Join (Directory, Path))),
                                            Loc.Named ("value", Planned.Inputs ("project_name"))])
                                        & ASCII.LF);
                     end if;
                  else
                     Append (Files_Said, (if Files_Said = Null_Unbounded_String then "" else ", ") & Path);
                  end if;
               end;
            end loop;
            for Position in Planned.Template_Facts.Iterate loop
               if not Planned.Discovered_Facts.Contains (Cf.Value_Maps.Key (Position)) then
                  Say ("cli.init.fact", [Loc.Named ("name", Cf.Value_Maps.Key (Position)),
                                         Loc.Named ("value", Cf.Value_Maps.Element (Position))]);
               end if;
            end loop;
            for Position in Planned.Discovered_Facts.Iterate loop
               Say ("cli.init.fact", [Loc.Named ("name", Cf.Value_Maps.Key (Position)),
                                      Loc.Named ("value", Cf.Value_Maps.Element (Position))]);
            end loop;

            --  A check the project's own policy will not run, with the
            --  setting that lets it.
            for Index in 1 .. R.Field_Count (Planned.Configuration) loop
               declare
                  Name : constant String := R.Field_Name (Planned.Configuration, Index);
               begin
                  if Ada.Strings.Fixed.Index (Name, "profile.") = Name'First then
                     declare
                        package Vf renames Model_Runner.Framework.Verification;
                        package Ex renames Model_Runner.Framework.Execution;
                        Checks : constant Vf.Check_List :=
                          Vf.Parse_Profile (R.Get (Planned.Configuration, Name));
                     begin
                        for Index in 1 .. Vf.Length (Checks) loop
                           declare
                              One     : constant Vf.Check := Vf.Element (Checks, Index);
                              Command : constant String := To_String (One.Command);
                              Why     : constant String :=
                                (if Command = "" then "" else Ex.Refusal (Rules, Command));
                              Words   : constant Model_Runner.Framework.Name_Lists.Vector :=
                                Ex.Words_Of (Command);
                           begin
                              if Why /= "" and then not Refused.Contains (Command) then
                                 Refused.Append (Command);
                                 Say ("cli.init.check_refused",
                                      [Loc.Named ("name", To_String (One.Label)),
                                       Loc.Named ("value", Command), Loc.Named ("detail", Why)]);
                                 Append (Warned, Pres.Next_Step_Value
                                                   (Screen, "cli.init.check_refused",
                                                    [Loc.Named ("name", To_String (One.Label)),
                                                     Loc.Named ("value", Command),
                                                     Loc.Named ("detail", Why)])
                                                 & ASCII.LF);
                                 if Ex.Needs_Shell (Command) then
                                    Fixes.Include ("scalar.execution.shell", "allowed");
                                 elsif not Words.Is_Empty then
                                    Fixes.Include
                                      ("set.execution.allowed+",
                                       (if Fixes.Contains ("set.execution.allowed+")
                                        then Fixes.Element ("set.execution.allowed+") & ","
                                        else "")
                                       & Ada.Directories.Simple_Name (Words.First_Element));
                                 end if;
                              end if;
                           end;
                        end loop;
                     end;
                  end if;
               end;
            end loop;

            --  Asked where the template wants it, and at a terminal wherever it
            --  writes into what is there or starts with a check it will refuse.
            --  A tree that holds tests, checked by a command that names none
            --  of them: said, as every verification would rest on a build.
            declare
               Checks_Text : Unbounded_String;
            begin
               for Index in 1 .. R.Field_Count (Planned.Configuration) loop
                  if Ada.Strings.Fixed.Index (R.Field_Name (Planned.Configuration, Index), "profile.") = 1 then
                     Append (Checks_Text, R.Get (Planned.Configuration,
                                                  R.Field_Name (Planned.Configuration, Index)));
                  end if;
               end loop;
               for Tests_Dir of Model_Runner.Framework.Name_Lists.Vector'(["tests", "test"]) loop
                  if Ada.Directories.Exists (Hostkit.Fs.Join (Directory, Tests_Dir))
                    and then Ada.Strings.Fixed.Index (To_String (Checks_Text), "test") = 0
                    and then not Planned.Files.Contains (Tests_Dir & "/alire.toml")
                  then
                     Say ("cli.init.tests_unrun", [Loc.Named ("path", Tests_Dir & "/")]);
                     Append (Warned, Pres.Next_Step_Value
                                       (Screen, "cli.init.tests_unrun",
                                        [Loc.Named ("path", Tests_Dir & "/")]) & ASCII.LF);
                     exit;
                  end if;
               end loop;
            end;

            --  Asked where the template wants it, and at a terminal always:
            --  the plan is the user's to see before it is written.
            if (R.Get (Planned.Configuration, "scalar.init.confirm") in "yes" | "true" | "required"
                or else Interactive)
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
                  Allow   : Unbounded_String;
               begin
                  for Position in Fixes.Iterate loop
                     Append (Allow, (if Allow = Null_Unbounded_String then "" else " ")
                                    & Cf.Value_Maps.Key (Position) & "="
                                    & Cf.Value_Maps.Element (Position));
                  end loop;
                  Choosers.Append
                    (Answers, (Label      => To_Unbounded_String
                                               (Pres.Message_Value (Screen, "cli.init.confirm.yes")),
                               Tag        => Null_Unbounded_String,
                               Details    => Plan_Text,
                               Selectable => True));
                  if not Fixes.Is_Empty then
                     Choosers.Append
                       (Answers, (Label      => To_Unbounded_String
                                                  (Pres.Next_Step_Value
                                                     (Screen, "cli.init.confirm.allow",
                                                      [Loc.Named ("detail", To_String (Allow))])),
                                  Tag        => Null_Unbounded_String,
                                  Details    => Null_Unbounded_String,
                                  Selectable => True));
                  end if;
                  if not Planned.Inputs.Is_Empty then
                     Choosers.Append
                       (Answers, (Label      => To_Unbounded_String
                                                  (Pres.Message_Value (Screen, "cli.init.confirm.change")),
                                  Tag        => Null_Unbounded_String,
                                  Details    => Inputs_Said,
                                  Selectable => True));
                  end if;
                  Choosers.Append
                    (Answers, (Label      => To_Unbounded_String
                                               (Pres.Message_Value (Screen, "cli.init.confirm.no")),
                               Tag        => Null_Unbounded_String,
                               Details    => Null_Unbounded_String,
                               Selectable => True));
                  declare
                     Heading : constant String :=
                       Pres.Next_Step_Value
                         (Screen, "cli.init.plan",
                          [Loc.Named ("name", Tp.Id (Tp.Root (Composed))),
                           Loc.Named ("version", Tp.Version (Tp.Root (Composed))),
                           Loc.Named ("path", Ada.Directories.Full_Name (Directory))])
                       & ASCII.LF
                       & (if Inputs_Said = Null_Unbounded_String then ""
                          else Pres.Next_Step_Value (Screen, "cli.init.short.inputs",
                                                     [Loc.Named ("detail", To_String (Inputs_Said))])
                               & ASCII.LF)
                       & (if Files_Said = Null_Unbounded_String and then Dirs_Said = Null_Unbounded_String
                          then Pres.Message_Value (Screen, "cli.init.short.nothing") & ASCII.LF
                          else Pres.Next_Step_Value
                                 (Screen, "cli.init.short.writes",
                                  [Loc.Named ("detail",
                                              To_String (Files_Said)
                                              & (if Dirs_Said = Null_Unbounded_String then ""
                                                 else (if Files_Said = Null_Unbounded_String then ""
                                                       else "; ")
                                                      & "directories " & To_String (Dirs_Said)))])
                               & ASCII.LF)
                       & (if Kept_Said = Null_Unbounded_String then ""
                          else Pres.Next_Step_Value (Screen, "cli.init.short.keeps",
                                                     [Loc.Named ("detail", To_String (Kept_Said))])
                               & ASCII.LF)
                       & To_String (Warned)
                       & Pres.Message_Value (Screen, "cli.init.confirm");
                     Picked : constant Natural :=
                       Choosers.Choose (Screen, "cli.init.confirm", Answers, Heading => Heading);
                     Change_At : constant Natural :=
                       (if Planned.Inputs.Is_Empty then 0 else Choosers.Length (Answers) - 1);
                  begin
                     if Picked = 0 or else Picked = Choosers.Length (Answers) then
                        Pres.Put_Note (Screen, "cli.init.cancelled");
                        Status := E.Exit_Cancelled;
                        return;
                     elsif Picked = Change_At then
                        --  Which, and its new value -- the one it has offered
                        --  to keep -- and the plan made again.
                        declare
                           Offer : Choosers.Choice_List;
                           Ids   : Model_Runner.Framework.Name_Lists.Vector;
                        begin
                           for Position in Planned.Inputs.Iterate loop
                              Ids.Append (Cf.Value_Maps.Key (Position));
                              Choosers.Append
                                (Offer, (Label      => To_Unbounded_String
                                                         (Cf.Value_Maps.Key (Position) & " = "
                                                          & Cf.Value_Maps.Element (Position)),
                                         Tag        => Null_Unbounded_String,
                                         Details    => To_Unbounded_String
                                                         (Described (Cf.Value_Maps.Key (Position))),
                                         Selectable => True));
                           end loop;
                           declare
                              Which : constant Natural :=
                                Choosers.Choose (Screen, "cli.init.choose_input", Offer);
                           begin
                              if Which > 0 then
                                 for Index in 1 .. Tp.Input_Count (Composed) loop
                                    declare
                                       Declared : Tp.Input_Declaration :=
                                         Cf.Resolved (Tp.Input_At (Composed, Index), Directory);
                                    begin
                                       if To_String (Declared.Id) = Ids (Which) then
                                          --  What it has now is what Enter keeps.
                                          Declared.Default := To_Unbounded_String
                                            (Planned.Inputs (Ids (Which)));
                                          declare
                                             Got : Boolean;
                                          begin
                                             Ask (Declared, Got);
                                          end;
                                       end if;
                                    end;
                                 end loop;
                              end if;
                           end;
                        end;
                        Changing := True;
                     else
                        Allowing := Picked = 2 and then not Fixes.Is_Empty;
                     end if;
                  end;
               end;
            end if;
         end;
         exit Planning when not Changing;
      end loop Planning;

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

      --  What the checks need, where that was asked for with the plan.
      if Allowing then
         declare
            Change   : Cf.Change_Plan;
            Revision : Natural;
         begin
            Cf.Plan_Change (Store, Fixes, Change, Outcome);
            if E.Is_Ok (Outcome) then
               Cf.Reconfigure (Store, Change, Revision, Outcome);
            end if;
            if E.Is_Error (Outcome) then
               Pres.Report (Screen, Outcome);
            else
               for Line of Change.Changed loop
                  Pres.Put_Message (Screen, "cli.init.allowed", [Loc.Named ("detail", Line)]);
               end loop;
            end if;
         end;
      end if;

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
          Loc.Named ("path", S.Root (Store))]);
      --  In a session, the steps after it are the session's commands, which
      --  work where the session was started: not offered for elsewhere.
      if not (Pres.In_Session (Screen) and then not T.Is_Empty (Item.Project_Directory)) then
         --  Documents there to read: named, as /bootstrap will read them.
         declare
            Found  : constant Model_Runner.Framework.Name_Lists.Vector :=
              Model_Runner.Framework.Bootstrap.Documents (Store);
            Listed : Unbounded_String;
            Count  : Natural := 0;
         begin
            for Path of Found loop
               Count := Count + 1;
               if Count <= 5 then
                  Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & Path);
               end if;
            end loop;
            if Found.Is_Empty then
               Pres.Put_Note (Screen, "cli.next.init");
            else
               Pres.Put_Note (Screen, "cli.next.init_documents",
                              [Loc.Named ("detail", To_String (Listed) & (if Count > 5 then ", ..." else ""))]);
            end if;
         end;
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
