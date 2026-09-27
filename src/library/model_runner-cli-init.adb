with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Configurations;
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

   --  A line typed at the terminal, or nothing at the end of input.
   function Answer return String is
   begin
      return Ada.Text_IO.Get_Line;
   exception
      when Ada.Text_IO.End_Error =>
         return "";
   end Answer;

   function Trimmed (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last and then Text (First) in ' ' | ASCII.HT | ASCII.CR
      loop
         First := First + 1;
      end loop;
      while Last >= First and then Text (Last) in ' ' | ASCII.HT | ASCII.CR
      loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trimmed;

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

      Interactive : constant Boolean :=
        Model_Runner.Platform.Is_Terminal (0)
        and then Model_Runner.Platform.Is_Terminal (2);

      Places   : Model_Runner.Framework.Name_Lists.Vector;
      Registry : Tp.Registry;
      Chosen   : Unbounded_String :=
        To_Unbounded_String (T.To_String (Item.Template_Name));
      Composed : Tp.Composition;
      Given    : Cf.Value_Maps.Map;
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

      --  The template a typed answer names: its number or its identifier.
      function Picked (Typed : String) return String is
         Number : Natural := 0;
      begin
         if Typed'Length in 1 .. 4
           and then (for all Char of Typed => Char in '0' .. '9')
         then
            Number := Natural'Value (Typed);
         end if;
         if Number in 1 .. Tp.Count (Registry) then
            return Tp.Id (Tp.Template_At (Registry, Number));
         end if;
         return Typed;
      end Picked;

      --  Ask for one input until it is given a value it takes, or the
      --  caller gives nothing.
      procedure Ask (Declared : Tp.Input_Declaration; Got : out Boolean) is
         Check : E.Error_Info;
      begin
         Got := False;
         loop
            Pres.Put_Note
              (Screen, "cli.init.input",
               [Loc.Named ("name", To_String (Declared.Label)),
                Loc.Named ("detail", To_String (Declared.Description))]);
            if Declared.Choices /= Null_Unbounded_String then
               Pres.Put_Note
                 (Screen, "cli.init.choices",
                  [Loc.Named ("value", To_String (Declared.Choices))]);
            end if;

            declare
               Typed : constant String := Trimmed (Answer);
            begin
               if Typed = "" then
                  return;
               end if;
               Cf.Check_Input (Declared, Typed, Check);
               if E.Is_Ok (Check) then
                  Given.Include (To_String (Declared.Id), Typed);
                  Got := True;
                  return;
               end if;
               Pres.Report (Screen, Check);
            end;
         end loop;
      end Ask;
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

         Pres.Put_Message (Screen, "cli.init.header");
         List;

         if not Interactive then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "template");
            Fail (Outcome);
            return;
         end if;

         Pres.Put_Note
           (Screen, "cli.init.choose",
            [Loc.Named ("count", T.Image (Long_Long_Integer (Tp.Count (Registry))))]);
         Chosen := To_Unbounded_String (Picked (Trimmed (Answer)));
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

      Pres.Put_Message
        (Screen, "cli.init.done",
         [Loc.Named ("name", S.Project_Name (Store)),
          Loc.Named ("path", S.Root (Store)),
          Loc.Named
            ("detail",
             R.Get (Planned.Configuration, "configuration_fingerprint"))]);
      S.Close (Store);
   end Run;

end Model_Runner.CLI.Init;
