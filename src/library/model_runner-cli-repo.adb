with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Traceability;
with Model_Runner.Localization;
with Model_Runner.Text;

package body Model_Runner.CLI.Repo is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;
   package Loc renames Model_Runner.Localization;
   package Pres renames Model_Runner.Presentation;
   package Rp renames Model_Runner.Framework.Repository;
   package S renames Model_Runner.Framework.Stores;
   package T renames Model_Runner.Text;
   package Tr renames Model_Runner.Framework.Traceability;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   --  The roots of the project in a directory: its configuration's, or
   --  the defaults for a directory that has no project state.
   function Roots_In (Directory : String) return Rp.Roots is
      Store   : S.Store;
      Report  : S.Recovery_Report;
      Outcome : E.Error_Info;
      Result  : Rp.Roots := Rp.Default_Roots;
   begin
      if S.Is_Initialized (Directory) then
         S.Open (Store, Directory, Report, Outcome);
         if E.Is_Ok (Outcome) then
            Result := Rp.Roots_Of (Store);
         end if;
         S.Close (Store);
      end if;
      return Result;
   end Roots_In;

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
      Action    : constant String :=
        (if T.Is_Empty (Item.Action) then "scan"
         else T.To_String (Item.Action));
      Argument  : constant String := T.To_String (Item.Action_Argument);
      Found     : constant Rp.Graph := Rp.Scan (Directory, Roots_In (Directory));
      Outcome   : E.Error_Info;

      procedure Fail (Condition : E.Error_Info) is
      begin
         Pres.Report (Screen, Condition);
         Status := E.Exit_Status (Condition);
      end Fail;

      procedure Not_Found is
      begin
         Outcome := E.Make (E.Framework_Not_Found);
         E.Add_Text (Outcome, "name", Argument);
         Fail (Outcome);
      end Not_Found;

      --  Keep the graph in the project's state, when it has one and the
      --  graph changed since it was last kept.
      procedure Keep is
         Store  : S.Store;
         Report : S.Recovery_Report;
         Kept   : Rp.Graph;
         Change : S.Transaction;
      begin
         if not S.Is_Initialized (Directory) then
            return;
         end if;
         S.Open (Store, Directory, Report, Outcome);
         if E.Is_Ok (Outcome) then
            Rp.Load (Store, Kept, Outcome);
            if E.Is_Error (Outcome)
              or else Rp.Graph_Fingerprint (Kept) /= Rp.Graph_Fingerprint (Found)
            then
               Rp.Keep (Store, Change, Found, Outcome);

               --  A graph that was kept before and differs now is source
               --  that changed, which the orchestrator acts on.
               if E.Is_Ok (Outcome) and then Rp.File_Count (Kept) > 0 then
                  declare
                     Event : Unbounded_String;
                  begin
                     Model_Runner.Framework.Events.Emit
                       (Store, Change, Model_Runner.Framework.Events.Source_Changed,
                        "PROJECT", Rp.Graph_Fingerprint (Found), Event, Outcome);
                  end;
               end if;
               if E.Is_Ok (Outcome) then
                  S.Commit (Store, Change, Outcome);
               end if;
            end if;
         end if;
         S.Close (Store);

         --  The graph is derived; failing to keep it is said, and the
         --  answer stands.
         if E.Is_Error (Outcome) and then Outcome.Code /= E.Framework_Not_Found
         then
            Outcome.Severity := E.Severity_Warning;
            Pres.Report (Screen, Outcome);
         end if;
      end Keep;
   begin
      Status := E.Exit_Success;

      if Action in "sym" | "refs" | "deps" | "users" | "impact" | "trace"
        and then Argument = ""
      then
         Outcome := E.Make (E.Framework_Input_Missing);
         E.Add_Text (Outcome, "name", (if Action in "deps" | "users" then "unit"
                                       elsif Action = "impact" then "file or symbol"
                                       elsif Action = "trace" then "node"
                                       else "symbol"));
         Fail (Outcome);
         return;
      end if;

      Keep;

      if Action = "scan" then
         Pres.Put_Message
           (Screen, "cli.repo.summary",
            [Loc.Named ("count", Image (Rp.File_Count (Found))),
             Loc.Named ("total", Image (Rp.Relation_Count (Found))),
             Loc.Named ("value", Rp.Graph_Fingerprint (Found))]);

      elsif Action = "tree" then
         for Index in 1 .. Rp.File_Count (Found) loop
            declare
               File : constant Rp.File_Entry := Rp.File_At (Found, Index);
            begin
               Pres.Put_Message
                 (Screen, "cli.repo.file",
                  [Loc.Named ("path", To_String (File.Path)),
                   Loc.Named ("value", To_String (File.Language)),
                   Loc.Named ("detail",
                              Ada.Characters.Handling.To_Lower
                                (Rp.File_Role'Image (File.Role)))]);
            end;
         end loop;

      elsif Action = "sym" then
         declare
            Names : constant Model_Runner.Framework.Name_Lists.Vector :=
              Rp.Find_Symbols (Found, Argument);
            Here  : Boolean;
         begin
            if Names.Is_Empty then
               Not_Found;
               return;
            end if;
            for Name of Names loop
               declare
                  Named : constant Rp.Symbol := Rp.Symbol_Of (Found, Name, Here);
               begin
                  Pres.Put_Message
                    (Screen, "cli.repo.symbol",
                     [Loc.Named ("name", Name),
                      Loc.Named ("value", To_String (Named.Kind)),
                      Loc.Named ("path", To_String (Named.Path) & ":"
                                         & Image (Named.Line))]);
               end;
            end loop;
         end;

      elsif Action = "refs" then
         declare
            Names : constant Model_Runner.Framework.Name_Lists.Vector :=
              Rp.Find_Symbols (Found, Argument);
         begin
            if Names.Is_Empty then
               Not_Found;
               return;
            end if;
            --  Each with how it was found and how sure that is: a name that
            --  matches is a guess, and says so.
            for Name of Names loop
               for Index in 1 .. Rp.Relation_Count (Found) loop
                  declare
                     use type Rp.Relation_Kind;
                     One : constant Rp.Relation := Rp.Relation_At (Found, Index);
                  begin
                     if One.Kind = Rp.References and then To_String (One.To) = Name then
                        Pres.Put_Message
                          (Screen, "cli.repo.reference",
                           [Loc.Named ("name", Name), Loc.Named ("path", To_String (One.Where)),
                            Loc.Named ("detail",
                                       Ada.Characters.Handling.To_Lower
                                         (Rp.Derivation'Image (One.Source) & ", "
                                          & Rp.Confidence'Image (One.Sure)))]);
                     end if;
                  end;
               end loop;
            end loop;
         end;

      elsif Action in "impact" | "trace" then
         declare
            Store  : S.Store;
            Report : S.Recovery_Report;
         begin
            S.Open (Store, Directory, Report, Outcome);
            if E.Is_Error (Outcome) then
               Fail (Outcome);
               return;
            end if;
            declare
               Graph : constant Tr.Graph := Tr.Build (Store, Found);
            begin
               if Action = "trace" then
                  for Place of Tr.Touching (Graph, Argument) loop
                     declare
                        One : constant Tr.Edge := Tr.Edge_At (Graph, Natural'Value (Place));
                     begin
                        Pres.Put_Message
                          (Screen, "cli.repo.edge",
                           [Loc.Named ("name", To_String (One.From)),
                            Loc.Named ("value", To_String (One.Kind)),
                            Loc.Named ("other", To_String (One.To)),
                            Loc.Named ("detail",
                                       Ada.Characters.Handling.To_Lower
                                         (Rp.Derivation'Image (One.Source) & ", "
                                          & Rp.Confidence'Image (One.Sure)))]);
                     end;
                  end loop;
               else
                  declare
                     Changed : Model_Runner.Framework.Name_Lists.Vector;
                     Reach   : Tr.Impact;
                     Chosen  : Tr.Selection;
                  begin
                     --  A file by its path; anything else is a symbol, by its
                     --  full or its last name.
                     declare
                        Is_File : Boolean := False;
                     begin
                        for Index in 1 .. Rp.File_Count (Found) loop
                           Is_File := Is_File
                             or else To_String (Rp.File_At (Found, Index).Path) = Argument;
                        end loop;
                        if not Is_File then
                           for Name of Rp.Find_Symbols (Found, Argument) loop
                              Changed.Append ("symbol:" & Name);
                           end loop;
                        end if;
                        if Changed.Is_Empty then
                           Changed.Append (Argument);
                        end if;
                     end;
                     Reach := Tr.Impact_Of (Graph, Changed);
                     for Index in 1 .. Tr.Length (Reach) loop
                        declare
                           One : constant Tr.Reached := Tr.Element (Reach, Index);
                        begin
                           Pres.Put_Message
                             (Screen, "cli.repo.reached",
                              [Loc.Named ("value", To_String (One.Kind)),
                               Loc.Named ("name", To_String (One.Id)),
                               Loc.Named ("detail",
                                          Ada.Characters.Handling.To_Lower
                                            (Rp.Confidence'Image (One.Sure)))]);
                        end;
                     end loop;
                     Chosen := Tr.Select_Tests (Store, Reach);
                     Pres.Put_Message
                       (Screen, "cli.repo.selection",
                        [Loc.Named ("value",
                                    Ada.Characters.Handling.To_Lower
                                      (Tr.Scope'Image (Chosen.Width))),
                         Loc.Named ("detail", To_String (Chosen.Reason))]);
                  end;
               end if;
            end;
            S.Close (Store);
         end;

      else
         declare
            Units : constant Model_Runner.Framework.Name_Lists.Vector :=
              (if Action = "deps" then Rp.Dependencies_Of (Found, Argument)
               else Rp.Dependents_Of (Found, Argument));
         begin
            for Unit of Units loop
               Pres.Put_Message
                 (Screen, "cli.repo.unit", [Loc.Named ("name", Unit)]);
            end loop;
         end;
      end if;
   end Run;

end Model_Runner.CLI.Repo;
