with Ada.Characters.Handling;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Hostkit.Fs;

with Model_Runner.CLI.Options;
with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Intent;
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
     (Item   : Model_Runner.CLI.Project_Requests.Request;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural)
   is
      Directory : constant String :=
        (if T.Is_Empty (Item.Project_Directory) then "."
         else T.To_String (Item.Project_Directory));
      Action    : constant String :=
        (if T.Is_Empty (Item.Action) then "scan"
         else T.To_String (Item.Action));
      Typed     : constant String := T.To_String (Item.Action_Argument);
      --  A path as the project names it: ./src/x.adb and a whole path into
      --  the project are src/x.adb, and . is the project itself.
      Argument  : constant String :=
        (if Typed = "." or else Ada.Strings.Fixed.Index (Typed, "/") > 0
         then Rp.Relative_Path
                (Ada.Directories.Full_Name
                   (if T.Is_Empty (Item.Project_Directory) then "."
                    else T.To_String (Item.Project_Directory)), Typed)
         else Typed);
      Recovered : Model_Runner.Framework.Name_Lists.Vector;
      Within    : constant Rp.Roots := Roots_In (Directory, Recovered);
      Found     : constant Rp.Graph := Rp.Scan (Directory, Within);
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

      --  An entity's identifier without the revision a node carries.
      function Bare_Id (Node : String) return String is
         At_Sign : constant Natural := Ada.Strings.Fixed.Index (Node, "@");
      begin
         return (if At_Sign = 0 then Node else Node (Node'First .. At_Sign - 1));
      end Bare_Id;

      --  A requirement's node as the graph names it: at its revision.
      function Revision_Node (Name : String) return String is
         Store  : S.Store;
         Got    : E.Error_Info;
         Held   : Model_Runner.Framework.Intent.Entity;
      begin
         if Name'Length < 5 or else Name (Name'First .. Name'First + 3) /= "REQ-"
           or else not S.Is_Initialized (Directory)
         then
            return Name;
         end if;
         S.Open_To_Read (Store, Directory, Got);
         if E.Is_Ok (Got) then
            Model_Runner.Framework.Intent.Read
              (Store, Model_Runner.Framework.Intent.Requirement, Name, Held, Got);
         end if;
         S.Close (Store);
         return (if E.Is_Ok (Got) then Name & "@" & Image (Held.Revision) else Name);
      end Revision_Node;

      Verbose : constant Boolean :=
        Model_Runner.CLI.Options."=" (Item.Level, Model_Runner.CLI.Options.Verbose);

      --  Keep the graph in the project's state, when it has one and the
      --  graph changed since it was last kept.
      procedure Keep is
         Store  : S.Store;
         Report : S.Recovery_Report;
         Change : S.Transaction;
      begin
         if not S.Is_Initialized (Directory) then
            return;
         end if;
         S.Open (Store, Directory, Report, Outcome);
         if E.Is_Ok (Outcome) then
            declare
               Kept : constant String := Rp.Kept_Fingerprint (Store);
            begin
               if Kept /= Rp.Graph_Fingerprint (Found) then
                  Rp.Keep (Store, Change, Found, Outcome);

                  --  A graph that was kept before and differs now is source
                  --  that changed, which the orchestrator acts on.
                  if E.Is_Ok (Outcome) and then Kept /= "" then
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
            end;
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
         --  In a session, what does not hold together was said as it opened.
         --  A reading of the repository is no place for what does not
         --  hold together in the state.
         if Ada.Strings.Fixed.Index (Line, "what does not hold together") /= Line'First then
            Pres.Put_Note (Screen, "cli.project.recovered", [Loc.Named ("detail", Line)]);
         end if;
      end loop;

      --  A path out of the project is none of its files.
      if Action in "impact" | "trace" | "deps" | "users" | "refs"
        and then Argument'Length > 0
        and then (Argument (Argument'First) = '/' or else Ada.Strings.Fixed.Index (Argument, "..") = Argument'First)
      then
         Outcome := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Outcome, "name", "a file of the project");
         E.Add_Text (Outcome, "value", Typed);
         E.Add_Text (Outcome, "detail", "it is outside the project; paths are relative to it");
         Fail (Outcome);
         return;
      end if;
      if Action in "sym" | "refs" | "deps" | "users" | "impact" | "trace"
        and then Argument = "" and then not (Action = "impact" and then Typed /= "")
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
         --  The directories left out, said: a source tree under one of
         --  them would be missed unseen.
         declare
            Left : Ada.Strings.Unbounded.Unbounded_String;
         begin
            for Skipped of Within.Skip loop
               declare
                  Place : constant String := Directory & "/" & Skipped;
               begin
                  if Ada.Strings.Fixed.Index (Skipped, "*") = 0 and then Ada.Directories.Exists (Place)
                    and then Ada.Directories."=" (Ada.Directories.Kind (Place), Ada.Directories.Directory)
                  then
                     Ada.Strings.Unbounded.Append
                       (Left, (if Left = Ada.Strings.Unbounded.Null_Unbounded_String then "" else ", ")
                              & Skipped & "/");
                  end if;
               end;
            end loop;
            if Left /= Ada.Strings.Unbounded.Null_Unbounded_String then
               Pres.Put_Note (Screen, "cli.repo.skipped",
                              [Loc.Named ("detail", Ada.Strings.Unbounded.To_String (Left))]);
            end if;
         end;

      elsif Action = "tree" then
         --  Under a directory, when one is named: its files only.
         declare
            Under : constant String :=
              (if Argument in "" | "." then ""
               elsif Argument (Argument'Last) = '/' then Argument else Argument & "/");
            Shown : Natural := 0;
         begin
            for Index in 1 .. Rp.File_Count (Found) loop
               declare
                  File : constant Rp.File_Entry := Rp.File_At (Found, Index);
                  Path : constant String := To_String (File.Path);
               begin
                  if Under = ""
                    or else (Path'Length > Under'Length
                             and then Path (Path'First .. Path'First + Under'Length - 1) = Under)
                    or else Path = Argument
                  then
                     Shown := Shown + 1;
                     Pres.Put_Message
                       (Screen, "cli.repo.file",
                        [Loc.Named ("path", Path),
                         Loc.Named ("value", To_String (File.Language)),
                         Loc.Named ("detail",
                                    Ada.Characters.Handling.To_Lower
                                      (Rp.File_Role'Image (File.Role)))]);
                  end if;
               end;
            end loop;
            if Shown = 0 and then Under /= "" then
               Not_Found;
               return;
            end if;
         end;

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
            --  more than once, and each is its own line. The declarations
            --  are gathered in one walk of the symbols, then said by name.
            declare
               package Symbol_Vectors is new Ada.Containers.Vectors (Positive, Rp.Symbol, Rp."=");
               Declared : Symbol_Vectors.Vector;
            begin
               for Index in 1 .. Rp.Symbol_Count (Found) loop
                  declare
                     Named : constant Rp.Symbol := Rp.Symbol_At (Found, Index);
                  begin
                     if Names.Contains (To_String (Named.Name)) then
                        Declared.Append (Named);
                     end if;
                  end;
               end loop;
               for Name of Names loop
                  for Named of Declared loop
                     if To_String (Named.Name) = Name then
                        Pres.Put_Message
                          (Screen, "cli.repo.symbol",
                           [Loc.Named ("name", Name),
                            Loc.Named ("value", To_String (Named.Kind)),
                            Loc.Named ("path", To_String (Named.Path) & ":"
                                               & Image (Named.Line))]);
                     end if;
                  end loop;
               end loop;
            end;
         end;

      elsif Action = "refs" then
         declare
            Names : constant Model_Runner.Framework.Name_Lists.Vector :=
              Rp.Find_Symbols (Found, Argument);
         begin
            --  A unit the repository does not declare -- a library's, the
            --  runtime's -- is still used where it is withed: those uses,
            --  said as what they are.
            if Names.Is_Empty then
               declare
                  Any : Boolean := False;
               begin
                  for Index in 1 .. Rp.Relation_Count (Found) loop
                     declare
                        use type Rp.Relation_Kind;
                        One : constant Rp.Relation := Rp.Relation_At (Found, Index);
                     begin
                        if One.Kind = Rp.Depends_On
                          and then Ada.Characters.Handling.To_Lower (To_String (One.To))
                                   = Ada.Characters.Handling.To_Lower (Argument)
                          and then Length (One.Where) > 0
                        then
                           Any := True;
                           Pres.Put_Message
                             (Screen, "cli.repo.reference",
                              [Loc.Named ("name", To_String (One.To)),
                               Loc.Named ("path", To_String (One.Where)),
                               Loc.Named ("detail", "withed; declared outside the repository")]);
                        end if;
                     end;
                  end loop;
                  if not Any then
                     Not_Found;
                  end if;
               end;
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
            declare
               Shown : Model_Runner.Framework.Name_Lists.Vector;
            begin
               for Name of Names loop
                  for Index in 1 .. Rp.Relation_Count (Found) loop
                     declare
                        use type Rp.Relation_Kind;
                        One : constant Rp.Relation := Rp.Relation_At (Found, Index);
                     begin
                        --  Each place once: the surest way it was found.
                        if One.Kind = Rp.References and then To_String (One.To) = Name
                          and then not Shown.Contains (Name & " " & To_String (One.Where))
                        then
                           Shown.Append (Name & " " & To_String (One.Where));
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
                     State_Edges, Code_Edges : Model_Runner.Framework.Name_Lists.Vector;
                  begin
                     --  A component the project has not: said, not traced.
                     if Ada.Strings.Fixed.Index (Argument, "component:") = Argument'First
                       and then not Tk.Components (Store).Contains
                                      (Argument (Argument'First + 10 .. Argument'Last))
                     then
                        Outcome := E.Make (E.Framework_Not_Found);
                        E.Add_Text (Outcome, "name", "a component called "
                                    & Argument (Argument'First + 10 .. Argument'Last));
                        Fail (Outcome);
                        S.Close (Store);
                        return;
                     end if;
                     Nodes.Append (Argument);
                     Nodes.Append ("file:" & Argument);
                     --  A directory is its files.
                     if Argument'Length > 0 and then Ada.Directories.Exists (Hostkit.Fs.Join (Directory, Argument))
                       and then Ada.Directories."=" (Ada.Directories.Kind (Hostkit.Fs.Join (Directory, Argument)),
                                                     Ada.Directories.Directory)
                     then
                        for Index in 1 .. Rp.File_Count (Found) loop
                           declare
                              Path : constant String := To_String (Rp.File_At (Found, Index).Path);
                              Bare : constant String :=
                                (if Argument (Argument'Last) = '/' then Argument (Argument'First .. Argument'Last - 1)
                                 else Argument);
                           begin
                              if Ada.Strings.Fixed.Index (Path, Bare & "/") = Path'First then
                                 Nodes.Append ("file:" & Path);
                              end if;
                           end;
                        end loop;
                     end if;
                     Nodes.Append (Revision_Node (Argument));
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
                              --  Each edge once, however it was reached;
                              --  what the project's state says of it first.
                              if not Shown.Contains (Line) then
                                 Shown.Append (Line);
                                 declare
                                    Said : constant String :=
                                      To_String (One.From) & " " & To_String (One.Kind) & " "
                                      & To_String (One.To) & " ("
                                      & Ada.Characters.Handling.To_Lower
                                          (Rp.Derivation'Image (One.Source) & ", "
                                           & Rp.Confidence'Image (One.Sure)) & ")";
                                 begin
                                    if Ada.Strings.Fixed.Index (Line, "REQ-") > 0
                                      or else Ada.Strings.Fixed.Index (Line, "TASK-") > 0
                                    then
                                       State_Edges.Append (Said);
                                    else
                                       Code_Edges.Append (Said);
                                    end if;
                                 end;
                              end if;
                           end;
                        end loop;
                     end loop;
                     for Line of State_Edges loop
                        Pres.Put_Message (Screen, "cli.repo.unit", [Loc.Named ("name", Line)]);
                     end loop;
                     for Index in 1 .. Natural (Code_Edges.Length) loop
                        if Verbose or else Index <= 30 then
                           Pres.Put_Message
                             (Screen, "cli.repo.unit", [Loc.Named ("name", Code_Edges (Index))]);
                        end if;
                     end loop;
                     if not Verbose and then Natural (Code_Edges.Length) > 30 then
                        Pres.Put_Message
                          (Screen, "cli.repo.more",
                           [Loc.Named ("count", Image (Natural (Code_Edges.Length) - 30)),
                            Loc.Named ("name", "edges")]);
                     end if;
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

                           --  A directory is the files in it: those the
                           --  repository reads, and the documents there.
                           declare
                              Bare : constant String :=
                                (if Argument'Length > 1 and then Argument (Argument'Last) = '/'
                                 then Argument (Argument'First .. Argument'Last - 1) else Argument);
                              Whole : constant String :=
                                (if Bare = "" then Directory else Hostkit.Fs.Join (Directory, Bare));
                              --  Within it: every file, for the project itself.
                              function Under (Path : String) return Boolean
                              is (Bare = "" or else Ada.Strings.Fixed.Index (Path, Bare & "/") = Path'First);
                              function Named (Simple : String) return String
                              is (if Bare = "" then Simple else Bare & "/" & Simple);
                           begin
                              if Ada.Directories.Exists (Whole)
                                and then Ada.Directories."=" (Ada.Directories.Kind (Whole),
                                                              Ada.Directories.Directory)
                              then
                                 for Index in 1 .. Rp.File_Count (Found) loop
                                    declare
                                       Path : constant String := To_String (Rp.File_At (Found, Index).Path);
                                    begin
                                       if Under (Path) then
                                          Changed.Append (Path);
                                       end if;
                                    end;
                                 end loop;
                                 declare
                                    Search : Ada.Directories.Search_Type;
                                    One    : Ada.Directories.Directory_Entry_Type;
                                 begin
                                    Ada.Directories.Start_Search
                                      (Search, Whole, "*.md",
                                       [Ada.Directories.Ordinary_File => True, others => False]);
                                    while Ada.Directories.More_Entries (Search) loop
                                       Ada.Directories.Get_Next_Entry (Search, One);
                                       if not Changed.Contains
                                                (Named (Ada.Directories.Simple_Name (One)))
                                       then
                                          Changed.Append (Named (Ada.Directories.Simple_Name (One)));
                                       end if;
                                    end loop;
                                    Ada.Directories.End_Search (Search);
                                 end;
                              end if;
                           end;
                        end if;
                        --  A requirement is its node at its revision.
                        if Revision_Node (Argument) /= Argument then
                           Changed.Append (Revision_Node (Argument));
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
                           declare
                              One  : constant Tr.Reached := Tr.Element (Reach, Index);
                              Name : constant String := Bare_Id (To_String (One.Id));
                           begin
                              --  Work ended and requirements retired are
                              --  nothing a change reaches now.
                              if not (To_String (One.Kind) = "task"
                                      and then Tk.State_Of (Store, Name) in "rejected" | "cancelled")
                                and then not (To_String (One.Kind) = "requirement"
                                              and then Model_Runner.Framework.Intent.State_Of
                                                         (Store, Model_Runner.Framework.Intent.Requirement,
                                                          Name)
                                                       in "rejected" | "obsolete" | "superseded")
                              then
                                 All_Reached.Append (One);
                              end if;
                              Ids.Append (To_String (One.Id));
                           end;
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
                                                          (Bare_Id (To_String (One.Id)))
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
                                         & Kind & ": " & Image (Of_Kind));
                              end if;
                           end;
                        end loop;
                        Pres.Put_Message
                          (Screen, "cli.repo.impact_summary",
                           [Loc.Named ("name", (if Argument = "" then "the project" else Argument)),
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

            --  A symbol that is no unit -- Lexer.Scan -- answered at its own
            --  level: the units whose files use it, or what the unit it is
            --  declared in depends on.
            Symbols : constant Model_Runner.Framework.Name_Lists.Vector :=
              (if Files_Of (Argument).Is_Empty and then Units_In (Argument).Is_Empty
               then Rp.Find_Symbols (Found, Argument)
               else Model_Runner.Framework.Name_Lists.Empty_Vector);

            function Of_Symbols return Model_Runner.Framework.Name_Lists.Vector is
               use type Rp.Relation_Kind;
               Result : Model_Runner.Framework.Name_Lists.Vector;
            begin
               for Named of Symbols loop
                  if Action = "users" then
                     for Index in 1 .. Rp.Relation_Count (Found) loop
                        declare
                           One : constant Rp.Relation := Rp.Relation_At (Found, Index);
                        begin
                           if One.Kind = Rp.References and then To_String (One.To) = Named then
                              for Unit of Units_In (To_String (One.From)) loop
                                 if not Result.Contains (Unit) then
                                    Result.Append (Unit);
                                 end if;
                              end loop;
                           end if;
                        end;
                     end loop;
                  else
                     declare
                        Dot   : constant Natural :=
                          Ada.Strings.Fixed.Index (Named, ".", Ada.Strings.Backward);
                        Owner : constant String :=
                          (if Dot = 0 then Named else Named (Named'First .. Dot - 1));
                     begin
                        for Unit of Rp.Dependencies_Of (Found, Owner) loop
                           if not Result.Contains (Unit) then
                              Result.Append (Unit);
                           end if;
                        end loop;
                     end;
                  end if;
               end loop;
               return Result;
            end Of_Symbols;

            Units : constant Model_Runner.Framework.Name_Lists.Vector :=
              (if Symbols.Is_Empty then Of_Units else Of_Symbols);
         begin
            if not Symbols.Is_Empty then
               Pres.Put_Note
                 (Screen, (if Action = "users" then "cli.repo.symbol_users" else "cli.repo.symbol_deps"),
                  [Loc.Named ("name", Argument)]);
            end if;
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
