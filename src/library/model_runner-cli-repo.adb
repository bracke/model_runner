with Ada.Characters.Handling;
with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Traceability;
with Model_Runner.Framework.Work;
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
   package Tk renames Model_Runner.Framework.Tasks;
   package Tr renames Model_Runner.Framework.Traceability;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   --  The roots of the project in a directory: its configuration's, or
   --  the defaults for a directory that has no project state.
   function Roots_In
     (Directory : String;
      Said      : in out Model_Runner.Framework.Name_Lists.Vector) return Rp.Roots
   is
      Store   : S.Store;
      Report  : S.Recovery_Report;
      Outcome : E.Error_Info;
      Result  : Rp.Roots := Rp.Default_Roots;
   begin
      if S.Is_Initialized (Directory) then
         S.Open (Store, Directory, Report, Outcome);
         if E.Is_Ok (Outcome) then
            --  What an interruption left is put right on opening, as every
            --  command that opens a project does; the caller says it.
            Model_Runner.Framework.Work.Recover_On_Opening (Store, Report, Said, Outcome);
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
      Recovered : Model_Runner.Framework.Name_Lists.Vector;
      Found     : constant Rp.Graph := Rp.Scan (Directory, Roots_In (Directory, Recovered));
      Outcome   : E.Error_Info;

      procedure Fail (Condition : E.Error_Info) is
      begin
         Pres.Report (Screen, Condition);
         Status := E.Exit_Status (Condition);
      end Fail;

      --  Nothing of that name: said as the answer it is, with the status
      --  a name not found has.
      procedure Not_Found is
      begin
         Pres.Put_Message (Screen, "cli.repo.none", [Loc.Named ("name", Argument)]);
         Status := E.Exit_Status (E.Make (E.Framework_Not_Found));
      end Not_Found;

      --  The units a file holds, and the files a unit is in: a file and
      --  its units are asked of as one another.
      function Units_In (Path : String) return Model_Runner.Framework.Name_Lists.Vector is
         use type Rp.Relation_Kind;
         Result : Model_Runner.Framework.Name_Lists.Vector;
      begin
         for Index in 1 .. Rp.Relation_Count (Found) loop
            declare
               One : constant Rp.Relation := Rp.Relation_At (Found, Index);
            begin
               if One.Kind = Rp.Contains and then To_String (One.From) = Path
                 and then not Result.Contains (To_String (One.To))
               then
                  Result.Append (To_String (One.To));
               end if;
            end;
         end loop;
         return Result;
      end Units_In;

      function Files_Of (Unit : String) return Model_Runner.Framework.Name_Lists.Vector is
         use type Rp.Relation_Kind;
         Result : Model_Runner.Framework.Name_Lists.Vector;
      begin
         for Index in 1 .. Rp.Relation_Count (Found) loop
            declare
               One : constant Rp.Relation := Rp.Relation_At (Found, Index);
            begin
               if One.Kind = Rp.Contains
                 and then Ada.Characters.Handling.To_Lower (To_String (One.To))
                          = Ada.Characters.Handling.To_Lower (Unit)
                 and then not Result.Contains (To_String (One.From))
               then
                  Result.Append (To_String (One.From));
               end if;
            end;
         end loop;
         return Result;
      end Files_Of;

      Verbose : constant Boolean :=
        Model_Runner.CLI.Options."=" (Item.Level, Model_Runner.CLI.Options.Verbose);

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
      for Line of Recovered loop
         Pres.Put_Note (Screen, "cli.project.recovered", [Loc.Named ("detail", Line)]);
      end loop;

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
         begin
            if Names.Is_Empty then
               Not_Found;
               return;
            end if;
            --  Every declaration of each: an overloaded name is declared
            --  more than once, and each is its own line.
            for Name of Names loop
               for Index in 1 .. Rp.Symbol_Count (Found) loop
                  declare
                     Named : constant Rp.Symbol := Rp.Symbol_At (Found, Index);
                  begin
                     if To_String (Named.Name) = Name then
                        Pres.Put_Message
                          (Screen, "cli.repo.symbol",
                           [Loc.Named ("name", Name),
                            Loc.Named ("value", To_String (Named.Kind)),
                            Loc.Named ("path", To_String (Named.Path) & ":"
                                               & Image (Named.Line))]);
                     end if;
                  end;
               end loop;
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
            declare
               Any : Boolean := False;
            begin
               for Index in 1 .. Rp.Relation_Count (Found) loop
                  declare
                     use type Rp.Relation_Kind;
                     One : constant Rp.Relation := Rp.Relation_At (Found, Index);
                  begin
                     Any := Any or else (One.Kind = Rp.References and then Names.Contains (To_String (One.To)));
                  end;
               end loop;
               if not Any then
                  Pres.Put_Message (Screen, "cli.repo.no_refs", [Loc.Named ("name", Argument)]);
               end if;
            end;
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
                  declare
                     --  The node as named, or as the file or the symbols a
                     --  shorter name is: Quote is symbol:Hostkit.Shell.Quote.
                     Nodes : Model_Runner.Framework.Name_Lists.Vector;
                     Shown : Model_Runner.Framework.Name_Lists.Vector;
                  begin
                     Nodes.Append (Argument);
                     Nodes.Append ("file:" & Argument);
                     for Name of Rp.Find_Symbols (Found, Argument) loop
                        Nodes.Append ("symbol:" & Name);
                     end loop;
                     for Node of Nodes loop
                        for Place of Tr.Touching (Graph, Node) loop
                           declare
                              One  : constant Tr.Edge := Tr.Edge_At (Graph, Natural'Value (Place));
                              Line : constant String :=
                                To_String (One.From) & " " & To_String (One.Kind) & " "
                                & To_String (One.To);
                           begin
                              --  Each edge once, however it was reached.
                              if not Shown.Contains (Line) then
                                 Shown.Append (Line);
                                 Pres.Put_Message
                                   (Screen, "cli.repo.edge",
                                    [Loc.Named ("name", To_String (One.From)),
                                     Loc.Named ("value", To_String (One.Kind)),
                                     Loc.Named ("other", To_String (One.To)),
                                     Loc.Named ("detail",
                                                Ada.Characters.Handling.To_Lower
                                                  (Rp.Derivation'Image (One.Source) & ", "
                                                   & Rp.Confidence'Image (One.Sure)))]);
                              end if;
                           end;
                        end loop;
                     end loop;
                     if Shown.Is_Empty then
                        Pres.Put_Message (Screen, "cli.repo.no_edges", [Loc.Named ("name", Argument)]);
                     end if;
                  end;
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

                           --  A unit is its files: what changing it reaches.
                           for Path of Files_Of (Argument) loop
                              Changed.Append (Path);
                           end loop;
                        end if;
                        if Changed.Is_Empty then
                           --  A file or a symbol that is not there reaches
                           --  nothing, and is said so; an entity of the
                           --  project's state is asked of as it is.
                           if not Is_File and then Ada.Strings.Fixed.Index (Argument, "-") = 0 then
                              Not_Found;
                              S.Close (Store);
                              return;
                           end if;
                           Changed.Append (Argument);
                        end if;
                     end;
                     Reach := Tr.Impact_Of (Graph, Changed);

                     --  What matters first first: requirements, tasks and
                     --  tests before files and symbols; a long run of one
                     --  kind cut to its first ten unless asked for whole.
                     declare
                        Order  : constant Model_Runner.Framework.Name_Lists.Vector :=
                          ["requirement", "task", "test", "specification", "decision",
                           "component", "file", "unit", "symbol", "other"];
                        Counts : Unbounded_String;

                        --  What it reaches, and the open tasks serving a
                        --  requirement it reaches: their work is what the
                        --  change touches too.
                        package Reached_Vectors is new Ada.Containers.Vectors
                          (Positive, Tr.Reached, Tr."=");
                        All_Reached : Reached_Vectors.Vector;
                        Ids         : Model_Runner.Framework.Name_Lists.Vector;
                     begin
                        for Index in 1 .. Tr.Length (Reach) loop
                           All_Reached.Append (Tr.Element (Reach, Index));
                           Ids.Append (To_String (Tr.Element (Reach, Index).Id));
                        end loop;
                        for Index in 1 .. Tr.Length (Reach) loop
                           declare
                              One : constant Tr.Reached := Tr.Element (Reach, Index);
                           begin
                              if To_String (One.Kind) = "requirement" then
                                 for Id of Tk.List (Store) loop
                                    if not Ids.Contains (Id)
                                      and then Tk.State_Of (Store, Id) not in "complete" | "cancelled" | "rejected"
                                    then
                                       declare
                                          Defined : Model_Runner.Framework.Records.Item;
                                          Read    : E.Error_Info;
                                       begin
                                          Tk.Definition (Store, Id, Defined, Read);
                                          if E.Is_Ok (Read)
                                            and then Model_Runner.Framework.Lines_Of
                                                       (Model_Runner.Framework.Records.Get
                                                          (Defined, "requirements")).Contains
                                                          (To_String (One.Id))
                                          then
                                             Ids.Append (Id);
                                             All_Reached.Append
                                               (Tr.Reached'(Kind => To_Unbounded_String ("task"),
                                                 Id   => To_Unbounded_String (Id),
                                                 Sure => One.Sure));
                                          end if;
                                       end;
                                    end if;
                                 end loop;
                              end if;
                           end;
                        end loop;
                        for Kind of Order loop
                           declare
                              Of_Kind : Natural := 0;
                           begin
                              for One of All_Reached loop
                                 begin
                                    if To_String (One.Kind) = Kind then
                                       Of_Kind := Of_Kind + 1;
                                       if Verbose or else Of_Kind <= 10 then
                                          Pres.Put_Message
                                            (Screen, "cli.repo.reached",
                                             [Loc.Named ("value", Kind),
                                              Loc.Named ("name", To_String (One.Id)),
                                              Loc.Named ("detail",
                                                         Ada.Characters.Handling.To_Lower
                                                           (Rp.Confidence'Image (One.Sure)))]);
                                       end if;
                                    end if;
                                 end;
                              end loop;
                              if not Verbose and then Of_Kind > 10 then
                                 Pres.Put_Message
                                   (Screen, "cli.repo.more",
                                    [Loc.Named ("count", Image (Of_Kind - 10)),
                                     Loc.Named ("name", Kind)]);
                              end if;
                              if Of_Kind > 0 then
                                 Append (Counts, (if Counts = Null_Unbounded_String then "" else ", ")
                                         & Image (Of_Kind) & " " & Kind);
                              end if;
                           end;
                        end loop;
                        Pres.Put_Message
                          (Screen, "cli.repo.impact_summary",
                           [Loc.Named ("name", Argument),
                            Loc.Named ("count", Image (Natural (All_Reached.Length))),
                            Loc.Named ("detail", To_String (Counts))]);
                     end;
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
            --  A unit by its name, or the units a file holds.
            function Of_Units return Model_Runner.Framework.Name_Lists.Vector is
               Asked  : Model_Runner.Framework.Name_Lists.Vector := Units_In (Argument);
               Result : Model_Runner.Framework.Name_Lists.Vector;
            begin
               if Asked.Is_Empty then
                  Asked.Append (Argument);
               end if;
               for Unit of Asked loop
                  declare
                     Linked : constant Model_Runner.Framework.Name_Lists.Vector :=
                       (if Action = "deps" then Rp.Dependencies_Of (Found, Unit)
                        else Rp.Dependents_Of (Found, Unit));
                  begin
                     for Other of Linked loop
                        if not Result.Contains (Other) then
                           Result.Append (Other);
                        end if;
                     end loop;
                  end;
               end loop;
               return Result;
            end Of_Units;

            Units : constant Model_Runner.Framework.Name_Lists.Vector := Of_Units;
         begin
            for Unit of Units loop
               Pres.Put_Message
                 (Screen, "cli.repo.unit", [Loc.Named ("name", Unit)]);
            end loop;
            if Units.Is_Empty then
               if Rp.Find_Symbols (Found, Argument).Is_Empty
                 and then Units_In (Argument).Is_Empty
                 and then Rp.Dependencies_Of (Found, Argument).Is_Empty
                 and then Rp.Dependents_Of (Found, Argument).Is_Empty
               then
                  Not_Found;
               else
                  Pres.Put_Message
                    (Screen, (if Action = "deps" then "cli.repo.no_deps" else "cli.repo.no_users"),
                     [Loc.Named ("name", Argument)]);
               end if;
            end if;
         end;
      end if;
   end Run;

end Model_Runner.CLI.Repo;
