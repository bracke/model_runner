with Ada.Characters.Handling;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit.Fs;

with Model_Runner.CLI.Options;
with Model_Runner.CLI.Project_Commands;
with Model_Runner.Errors;
with Model_Runner.Framework.Consistency;
with Model_Runner.Framework;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Bootstrap;
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

   --  A node as a person names it: no file: or symbol: before it, no
   --  @revision after it.
   function Node_Said (Node : String) return String is
      Bare : constant String :=
        (if Node'Length > 5 and then Node (Node'First .. Node'First + 4) = "file:"
         then Node (Node'First + 5 .. Node'Last)
         elsif Node'Length > 7 and then Node (Node'First .. Node'First + 6) = "symbol:"
         then Node (Node'First + 7 .. Node'Last)
         elsif Node'Length > 10 and then Node (Node'First .. Node'First + 9) = "component:"
         then "the component " & Node (Node'First + 10 .. Node'Last)
         else Node);
      At_Mark : constant Natural := Ada.Strings.Fixed.Index (Bare, "@", Ada.Strings.Backward);
   begin
      return (if At_Mark > Bare'First and then (for all C of Bare (At_Mark + 1 .. Bare'Last) => C in '0' .. '9')
              then Bare (Bare'First .. At_Mark - 1) else Bare);
   end Node_Said;

   --  An edge of the trace as a sentence.
   function Edge_Said (From, Kind, To : String; Sure : Boolean) return String is
      Missing : constant Boolean := Ada.Strings.Fixed.Index (Kind, ", missing") > 0;
      Bare    : constant String :=
        (if Missing then Kind (Kind'First .. Ada.Strings.Fixed.Index (Kind, ", missing") - 1) else Kind);
      F       : constant String := Node_Said (From);
      To_Said : constant String := Node_Said (To) & (if Missing then " (missing)" else "");
   begin
      return (if Bare = "sources" then Node_Said (To) & " comes from " & F & (if Missing then " (missing)" else "")
              elsif Bare = "served_by" then F & " is served by " & To_Said
              elsif Bare = "implemented_by" then F & " is implemented by " & To_Said
              elsif Bare = "tested_by" then F & " is tested by " & To_Said
              --  Checked by evidence, which verifies it only while its
              --  state says so: /req show says that.
              elsif Bare = "verified_by" then F & " is checked by " & To_Said
              elsif Bare = "part_of" then F & " is part of " & To_Said
              elsif Bare = "depends_on" then F & " depends on " & To_Said
              elsif Bare in "scope" | "belongs_to" then F & " belongs to " & To_Said
              elsif Bare = "serves" then F & " serves " & To_Said
              else F & " " & Ada.Strings.Fixed.Translate (Bare, Ada.Strings.Maps.To_Mapping ("_", " "))
                   & " " & To_Said)
        --  Missing is said already; an explicit link is no guess.
        & (if Sure or else Missing then "" else ", probably");
   end Edge_Said;

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
      --  Typed where the session was started, below the project's top:
      --  basket.py in src/shop is src/shop/basket.py, where only that is.
      Below     : constant String := Model_Runner.CLI.Project_Commands.Started_Below;
      Top       : constant String :=
        Ada.Directories.Full_Name
          (if T.Is_Empty (Item.Project_Directory) then "." else T.To_String (Item.Project_Directory));
      --  ../x from there is from there, whether there is such a file or
      --  not -- inside the project, it is one of its paths.
      function Below_Whole return String is
      begin
         return Ada.Directories.Full_Name (Hostkit.Fs.Join (Hostkit.Fs.Join (Top, Below), Typed));
      exception
         when others =>
            return "";
      end Below_Whole;
      From_Here : constant String :=
        (if Below /= "" and then Typed /= "" and then Typed (Typed'First) /= '/'
           and then ((not Ada.Directories.Exists (Hostkit.Fs.Join (Top, Typed))
                      and then Ada.Directories.Exists (Hostkit.Fs.Join (Hostkit.Fs.Join (Top, Below), Typed)))
                     or else (Ada.Strings.Fixed.Index (Typed, "..") = Typed'First
                              and then Below_Whole'Length > Top'Length
                              and then Ada.Strings.Fixed.Index (Below_Whole, Top & "/") = Below_Whole'First))
         then (if Ada.Strings.Fixed.Index (Typed, "..") = Typed'First then Below_Whole else Below & "/" & Typed)
         else Typed);
      Argument  : constant String :=
        (if From_Here = "." or else Ada.Strings.Fixed.Index (From_Here, "/") > 0
         then Rp.Relative_Path (Top, From_Here)
         else From_Here);
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
         Unread : Boolean := False;
      begin
         --  A file there is, in a language not read for what it holds: said
         --  so, not as if there were no such file.
         for Index in 1 .. Rp.File_Count (Found) loop
            if To_String (Rp.File_At (Found, Index).Path) = Argument
              and then To_String (Rp.File_At (Found, Index).Language)
                       not in "Ada" | "C" | "C++" | "Rust" | "Python"
            then
               Unread := True;
            end if;
         end loop;
         if Unread then
            Pres.Put_Message (Screen, "cli.repo.unread_language", [Loc.Named ("name", Argument)]);
         else
            --  A file's path, and no such file now: gone, said so -- not as
            --  a name nothing is called.
            if Ada.Strings.Fixed.Index (Argument, "/") > 0 and then Ada.Strings.Fixed.Index (Argument, ".") > 0
              and then not Ada.Directories.Exists (Argument)
              --  One the history holds: there before; never there is nothing.
              and then Model_Runner.Framework.Git.Last_Commit_At (".", Argument) /= ""
            then
               declare
                  Became : constant String := Model_Runner.Framework.Git.Renamed_In_History (".", Argument);
               begin
                  --  Renamed, as git tells it: the new name, to ask of.
                  if Became /= "" then
                     Pres.Put_Message (Screen, "cli.repo.file_moved",
                                       [Loc.Named ("name", Argument), Loc.Named ("value", Became)]);
                  else
                     Pres.Put_Message (Screen, "cli.repo.file_gone", [Loc.Named ("name", Argument)]);
                  end if;
               end;
            else
               Pres.Put_Message (Screen, "cli.repo.none", [Loc.Named ("name", Argument)]);
            end if;
            --  A file gone that what is left still uses: named, as what its
            --  going breaks.
            if Action in "impact" | "users" | "deps" and then Ada.Strings.Fixed.Index (Argument, ".") > 0 then
               declare
                  use type Rp.Relation_Kind;
                  Simple : constant String := Ada.Directories.Simple_Name (Argument);
                  Dot    : constant Natural := Ada.Strings.Fixed.Index (Simple, ".", Ada.Strings.Backward);
                  Stem   : constant String := (if Dot > Simple'First then Simple (Simple'First .. Dot - 1) else Simple);
                  Users  : Model_Runner.Framework.Name_Lists.Vector;
               begin
                  for Index in 1 .. Rp.Relation_Count (Found) loop
                     declare
                        One : constant Rp.Relation := Rp.Relation_At (Found, Index);
                        To  : constant String := Ada.Characters.Handling.To_Lower (To_String (One.To));
                        Low : constant String := Ada.Characters.Handling.To_Lower (Stem);
                     begin
                        if One.Kind = Rp.Depends_On and then Low'Length > 2
                          and then (To = Low
                                    or else (To'Length > Low'Length
                                             and then To (To'Last - Low'Length .. To'Last) in "." & Low | "/" & Low))
                          and then not Users.Contains (To_String (One.From))
                        then
                           Users.Append (To_String (One.From));
                        end if;
                     end;
                  end loop;
                  if not Users.Is_Empty then
                     declare
                        Said : Unbounded_String;
                     begin
                        for One of Users loop
                           Append (Said, (if Said = Null_Unbounded_String then "" else ", ") & Node_Said (One));
                        end loop;
                        Pres.Put_Note (Screen, "cli.repo.gone_used_by",
                                       [Loc.Named ("name", Argument), Loc.Named ("detail", To_String (Said))]);
                     end;
                  end if;
               end;
            end if;
            --  A file, where a symbol was asked for: what takes a file.
            if Action in "refs" | "sym"
              and then (for some Index in 1 .. Rp.File_Count (Found) =>
                          To_String (Rp.File_At (Found, Index).Path) = Argument)
            then
               Pres.Put_Note (Screen, "cli.repo.file_not_symbol", [Loc.Named ("name", Argument)]);
               return;
            end if;
            --  An entry of the project's state is traced, not looked up in
            --  the code; and code in a language not read may hold it.
            if (for some Prefix of Model_Runner.Framework.Name_Lists.Vector'(["REQ-", "DEC-", "SPEC-", "TASK-"])
                  => Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Upper (Argument), Prefix) = 1)
            then
               Pres.Put_Note (Screen, "cli.repo.trace_instead", [Loc.Named ("name", Argument)]);
               --  Its document's label is what the code names: that, to look for.
               declare
                  Store : S.Store;
                  Read  : E.Error_Info;
                  Held  : Model_Runner.Framework.Intent.Entity;
               begin
                  S.Open_To_Read (Store, Directory, Read);
                  if E.Is_Ok (Read) then
                     Model_Runner.Framework.Intent.Read
                       (Store, Model_Runner.Framework.Intent.Requirement,
                        Ada.Characters.Handling.To_Upper (Argument), Held, Read);
                     if E.Is_Ok (Read) and then Ada.Strings.Unbounded.Index (Held.Provenance, "#") > 0 then
                        declare
                           Whole : constant String := To_String (Held.Provenance);
                           Label : constant String := Whole (Ada.Strings.Fixed.Index (Whole, "#") + 1 .. Whole'Last);
                        begin
                           if Label'Length in 3 .. 11 and then Label /= Ada.Characters.Handling.To_Upper (Argument)
                           then
                              Pres.Put_Note (Screen, "cli.repo.refs_label",
                                             [Loc.Named ("name", Argument), Loc.Named ("value", Label)]);
                           end if;
                        end;
                     end if;
                     S.Close (Store);
                  end if;
               exception
                  when others =>
                     S.Close (Store);
               end;
            --  A path is a file's, of its own kind: no other language holds it.
            elsif Ada.Strings.Fixed.Index (Argument, "/") > 0 then
               null;
            else
               declare
                  Kinds : Unbounded_String;
               begin
                  for Index in 1 .. Rp.File_Count (Found) loop
                     declare
                        Path : constant String := To_String (Rp.File_At (Found, Index).Path);
                        Dot  : constant Natural := Ada.Strings.Fixed.Index (Path, ".", Ada.Strings.Backward);
                        Ext  : constant String := (if Dot = 0 then "" else Path (Dot .. Path'Last));
                     begin
                        if To_String (Rp.File_At (Found, Index).Language) not in "Ada" | "C" | "C++" | "Rust" | "Python"
                          and then Ext in ".js" | ".mjs" | ".cjs" | ".jsx" | ".ts" | ".tsx" | ".java" | ".go"
                                        | ".rb" | ".cs" | ".kt" | ".swift" | ".php" | ".scala" | ".lua" | ".pl"
                          and then Ada.Strings.Unbounded.Index (Kinds, Ext) = 0
                        then
                           Append (Kinds, (if Kinds = Null_Unbounded_String then "" else ", ") & Ext);
                        end if;
                     end;
                  end loop;
                  if Kinds /= Null_Unbounded_String then
                     Pres.Put_Note (Screen, "cli.repo.unread_may_hold",
                                    [Loc.Named ("name", Argument), Loc.Named ("detail", To_String (Kinds))]);
                  end if;
               end;
            end if;
         end if;
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
      --  Something given that names nothing -- . for the whole project --
      --  is said as what it is, not as nothing given.
      if Action in "sym" | "refs" | "deps" | "users" | "trace"
        and then Argument = "" and then Typed /= ""
      then
         Outcome := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Outcome, "name", (if Action in "deps" | "users" then "a unit"
                                       elsif Action = "trace" then "what to trace"
                                       else "a symbol"));
         E.Add_Text (Outcome, "value", Typed);
         E.Add_Text (Outcome, "detail", (if Action in "deps" | "users" then "a unit is named as /tree lists it"
                                         elsif Action = "trace" then "it is a requirement, a task, a file or"
                                                                     & " a symbol"
                                         else "a symbol is named as /sym finds it"));
         Fail (Outcome);
         return;
      end if;
      if Action in "sym" | "refs" | "deps" | "users" | "impact" | "trace"
        and then Argument = "" and then not (Action = "impact" and then Typed /= "")
      then
         Outcome := E.Make (E.Framework_Input_Missing);
         --  Named with how it is given: the command and what it takes.
         E.Add_Text (Outcome, "name", (if Action in "deps" | "users"
                                       then "a unit or a file: /" & Action & " UNIT-or-FILE, as /deps"
                                            & " src/main.c or /deps a unit /sym names"
                                       elsif Action = "impact" then "a file or a symbol: /impact FILE-or-SYMBOL"
                                       elsif Action = "trace" then "what to trace: /trace ID-or-FILE-or-SYMBOL, as"
                                                                   & " /trace REQ-001 or /trace src/main.c"
                                       else "a symbol: /" & Action & " NAME, as /sym finds it"));
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
         --  What could not be read: named, so a graph missing a file is
         --  not taken for the whole project.
         if Rp.Unread_Count (Found) > 0 then
            declare
               Said : Ada.Strings.Unbounded.Unbounded_String;
            begin
               for Index in 1 .. Rp.Unread_Count (Found) loop
                  Ada.Strings.Unbounded.Append
                    (Said, (if Index = 1 then "" else "; ") & Rp.Unread_At (Found, Index));
               end loop;
               Pres.Put_Note (Screen, "cli.repo.not_read",
                              [Loc.Named ("count", Image (Rp.Unread_Count (Found))),
                               Loc.Named ("detail", Ada.Strings.Unbounded.To_String (Said))]);
            end;
         end if;
         --  Source in a language whose symbols are not read: named, so a
         --  /sym or /deps that finds nothing there is no surprise.
         declare
            Langs : Model_Runner.Framework.Name_Lists.Vector;
         begin
            for Index in 1 .. Rp.File_Count (Found) loop
               declare
                  Language : constant String := To_String (Rp.File_At (Found, Index).Language);
               begin
                  if Language in "Go" | "TypeScript" | "JavaScript" | "Java" and then not Langs.Contains (Language)
                  then
                     Langs.Append (Language);
                  end if;
               end;
            end loop;
            if not Langs.Is_Empty then
               declare
                  Said : Unbounded_String;
               begin
                  for One of Langs loop
                     Append (Said, (if Said = Null_Unbounded_String then "" else ", ") & One);
                  end loop;
                  Pres.Put_Note (Screen, "cli.repo.languages_unread", [Loc.Named ("detail", To_String (Said))]);
               end;
            end if;
         end;
         --  A file a requirement is linked to that the scan no longer
         --  finds -- removed, renamed: said now, not left to /check.
         declare
            Store  : S.Store;
            Report : S.Recovery_Report;
            Opened : E.Error_Info;
         begin
            S.Open (Store, Directory, Report, Opened);
            if E.Is_Ok (Opened) then
               declare
                  package Cs renames Model_Runner.Framework.Consistency;
                  Wrong : constant Cs.Finding_List := Cs.Check (Store);
               begin
                  for Index in 1 .. Cs.Length (Wrong) loop
                     if Cs."=" (Cs.Element (Wrong, Index).Kind, Cs.Missing_File) then
                        Pres.Put_Note (Screen, "cli.repo.link_missing",
                                       [Loc.Named ("name", To_String (Cs.Element (Wrong, Index).Subject)),
                                        Loc.Named ("detail", To_String (Cs.Element (Wrong, Index).Detail))]);
                     end if;
                  end loop;
               end;
               S.Close (Store);
            end if;
         exception
            when others =>
               null;
         end;
         --  Source in a language not read: counted, by its kinds, so an
         --  empty graph is not taken for an empty project.
         declare
            Unread : Natural := 0;
            Kinds  : Model_Runner.Framework.Name_Lists.Vector;
         begin
            for Index in 1 .. Rp.File_Count (Found) loop
               declare
                  Path : constant String := To_String (Rp.File_At (Found, Index).Path);
                  Dot  : constant Natural := Ada.Strings.Fixed.Index (Path, ".", Ada.Strings.Backward);
                  Ext  : constant String := (if Dot = 0 then "" else Path (Dot .. Path'Last));
               begin
                  if To_String (Rp.File_At (Found, Index).Language) = ""
                    and then Ext in ".js" | ".mjs" | ".cjs" | ".jsx" | ".ts" | ".tsx" | ".java" | ".go" | ".rb"
                                  | ".cs" | ".kt" | ".swift" | ".php" | ".scala" | ".lua" | ".pl"
                  then
                     Unread := Unread + 1;
                     if not Kinds.Contains (Ext) then
                        Kinds.Append (Ext);
                     end if;
                  end if;
               end;
            end loop;
            if Unread > 0 then
               declare
                  Said : Unbounded_String;
               begin
                  for One of Kinds loop
                     Append (Said, (if Said = Null_Unbounded_String then "" else ", ") & One);
                  end loop;
                  Pres.Put_Note (Screen, "cli.repo.unread_files",
                                 [Loc.Named ("count", Image (Unread)), Loc.Named ("detail", To_String (Said))]);
               end;
            end if;
         end;
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
            Shown    : Natural := 0;
            Last_Dir : Unbounded_String;
            Rows     : Model_Runner.Framework.Name_Lists.Vector;
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
                     --  By directory: each one's title once, its files set
                     --  in under it, their language and role muted.
                     declare
                        Slash : constant Natural := Ada.Strings.Fixed.Index (Path, "/", Ada.Strings.Backward);
                        Dir   : constant String := (if Slash = 0 then "./" else Path (Path'First .. Slash));
                        Leaf  : constant String := (if Slash = 0 then Path else Path (Slash + 1 .. Path'Last));
                     begin
                        if Pres.Is_Structured (Screen) then
                           Pres.Put_Message
                             (Screen, "cli.repo.file",
                              [Loc.Named ("path", Path),
                               Loc.Named ("value", To_String (File.Language)),
                               Loc.Named ("detail",
                                          Ada.Characters.Handling.To_Lower
                                            (Rp.File_Role'Image (File.Role)))]);
                        else
                           --  Gathered, to be said by directory in order.
                           Rows.Append (Dir & ASCII.HT & Leaf & ASCII.HT
                                        & To_String (File.Language)
                                        & (if Length (File.Language) > 0 then ", " else "")
                                        & Ada.Characters.Handling.To_Lower (Rp.File_Role'Image (File.Role)));
                        end if;
                     end;
                  end if;
               end;
            end loop;
            if Shown = 0 and then Under /= "" then
               Not_Found;
               return;
            end if;
            --  One title a directory, the directories in order, each one's
            --  files in order under it.
            declare
               package Sorting is new Model_Runner.Framework.Name_Lists.Generic_Sorting;
            begin
               Sorting.Sort (Rows);
               for Row of Rows loop
                  declare
                     First  : constant Natural := Ada.Strings.Fixed.Index (Row, [1 => ASCII.HT]);
                     Second : constant Natural :=
                       Ada.Strings.Fixed.Index (Row (First + 1 .. Row'Last), [1 => ASCII.HT]);
                     Dir    : constant String := Row (Row'First .. First - 1);
                  begin
                     if Dir /= To_String (Last_Dir) then
                        Pres.Put_Header (Screen, "cli.repo.directory", [Loc.Named ("path", Dir)]);
                        Last_Dir := To_Unbounded_String (Dir);
                     end if;
                     Pres.Put_Row (Screen, Row (First + 1 .. Second - 1), Row (Second + 1 .. Row'Last), Indent => 2);
                  end;
               end loop;
            end;
         end;

      elsif Action = "sym" then
         declare
            --  As named; else every symbol holding it, whatever the case,
            --  a * standing for anything: valid, VALID_SKU, valid*.
            function Looked_Up return Model_Runner.Framework.Name_Lists.Vector is
               Exact : constant Model_Runner.Framework.Name_Lists.Vector := Rp.Find_Symbols (Found, Argument);
               Wanted : constant String :=
                 Ada.Characters.Handling.To_Lower
                   (Ada.Strings.Fixed.Trim (Argument, Ada.Strings.Maps.To_Set ("*"), Ada.Strings.Maps.To_Set ("*")));
               Result : Model_Runner.Framework.Name_Lists.Vector;
            begin
               if not Exact.Is_Empty or else Wanted = "" then
                  return Exact;
               end if;
               for Index in 1 .. Rp.Symbol_Count (Found) loop
                  declare
                     Name : constant String := To_String (Rp.Symbol_At (Found, Index).Name);
                  begin
                     if Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Name), Wanted) > 0
                       and then not Result.Contains (Name)
                       and then Natural (Result.Length) < 30
                     then
                        Result.Append (Name);
                     end if;
                  end;
               end loop;
               return Result;
            end Looked_Up;
            Names : constant Model_Runner.Framework.Name_Lists.Vector := Looked_Up;
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
                        --  The name, then its kind and where, muted.
                        if Pres.Is_Structured (Screen) then
                           Pres.Put_Message
                             (Screen, "cli.repo.symbol",
                              [Loc.Named ("name", Name),
                               Loc.Named ("value", To_String (Named.Kind)),
                               Loc.Named ("path", To_String (Named.Path) & ":"
                                                  & Image (Named.Line))]);
                        else
                           Pres.Put_Row (Screen, Name, To_String (Named.Kind) & " at " & To_String (Named.Path)
                                                       & ":" & Image (Named.Line));
                        end if;
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
                  --  A label -- FR-1, REQ-9 -- is no symbol: the lines that
                  --  name it, as the text has them.
                  if not Any and then Ada.Strings.Fixed.Index (Argument, "-") > Argument'First
                    and then Argument (Argument'Last) in '0' .. '9'
                  then
                     for Index in 1 .. Rp.File_Count (Found) loop
                        declare
                           use Ada.Text_IO;
                           Path : constant String := To_String (Rp.File_At (Found, Index).Path);
                           File : File_Type;
                           Line_Number : Natural := 0;
                        begin
                           Open (File, In_File, Hostkit.Fs.Join (Directory, Path));
                           while not End_Of_File (File) loop
                              declare
                                 Line : constant String := Get_Line (File);
                                 At_Word : constant Natural := Ada.Strings.Fixed.Index (Line, Argument);
                              begin
                                 Line_Number := Line_Number + 1;
                                 if At_Word > 0
                                   and then (At_Word + Argument'Length > Line'Last
                                             or else Line (At_Word + Argument'Length) not in '0' .. '9')
                                   and then (At_Word = Line'First
                                             or else Line (At_Word - 1) not in 'A' .. 'Z' | 'a' .. 'z' | '-')
                                 then
                                    Any := True;
                                    Pres.Put_Message
                                      (Screen, "cli.repo.reference",
                                       [Loc.Named ("name", Argument),
                                        Loc.Named ("path", Path & ":" & Image (Line_Number)),
                                        Loc.Named ("detail", "named in the text")]);
                                 end if;
                              end;
                           end loop;
                           Close (File);
                        exception
                           when others =>
                              if Is_Open (File) then
                                 Close (File);
                              end if;
                        end;
                     end loop;
                  end if;
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
                     --  Links to files gone, each with what takes it off.
                     Missing_Links : Model_Runner.Framework.Name_Lists.Vector;
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
                                    --  In words: REQ-001 comes from README.md, its
                                    --  revision and how sure only when asked for.
                                    Said : constant String :=
                                      (if Verbose
                                       then To_String (One.From) & " " & To_String (One.Kind) & " "
                                            & To_String (One.To) & " ("
                                            & Ada.Characters.Handling.To_Lower
                                                (Rp.Derivation'Image (One.Source) & ", "
                                                 & Rp.Confidence'Image (One.Sure)) & ")"
                                       else Edge_Said (To_String (One.From), To_String (One.Kind),
                                                       To_String (One.To),
                                                       Rp."=" (One.Sure, Rp.Certain)));
                                 begin
                                    if (for some Prefix of Model_Runner.Framework.Name_Lists.Vector'
                                          (["REQ-", "TASK-", "DEC-", "SPEC-"]) =>
                                          Ada.Strings.Fixed.Index (Line, Prefix) > 0)
                                    then
                                       State_Edges.Append (Said);
                                       --  A linked file gone: the way to take the
                                       --  link off, or to the file it became.
                                       if Ada.Strings.Fixed.Index (To_String (One.Kind), ", missing") > 0
                                         and then Ada.Strings.Fixed.Index (To_String (One.From), "REQ-") = 1
                                       then
                                          declare
                                             Bare : constant String :=
                                               To_String (One.Kind)
                                                 (To_String (One.Kind)'First
                                                  .. Ada.Strings.Fixed.Index (To_String (One.Kind), ", missing") - 1);
                                             Word : constant String :=
                                               (if Bare = "implemented_by" then "implementation"
                                                elsif Bare = "tested_by" then "test" else "");
                                          begin
                                             if Word /= "" then
                                                Missing_Links.Append
                                                  ("/req unlink "
                                                   --  The entry, not its revision: REQ-12, not REQ-12@4.
                                                   & (if Ada.Strings.Fixed.Index (To_String (One.From), "@") > 0
                                                      then To_String (One.From)
                                                             (To_String (One.From)'First
                                                              .. Ada.Strings.Fixed.Index (To_String (One.From), "@")
                                                                 - 1)
                                                      else To_String (One.From))
                                                   & " " & Word & " "
                                                   & Node_Said (To_String (One.To)));
                                             end if;
                                          end;
                                       end if;
                                    else
                                       Code_Edges.Append (Said);
                                    end if;
                                 end;
                              end if;
                           end;
                        end loop;
                     end loop;
                     --  What the project's state says of it, and what the
                     --  code does, each under its title.
                     if not State_Edges.Is_Empty then
                        Pres.Put_Header (Screen, "cli.repo.section.state");
                     end if;
                     for Line of State_Edges loop
                        Pres.Put_Indented (Screen, "cli.repo.unit", [Loc.Named ("name", Line)]);
                     end loop;
                     for Step of Missing_Links loop
                        Pres.Put_Note (Screen, "cli.next.trace_missing", [Loc.Named ("value", Step)]);
                     end loop;
                     if not Code_Edges.Is_Empty then
                        if State_Edges.Is_Empty then
                           Pres.Put_Header (Screen, "cli.repo.section.code");
                        else
                           Pres.Put_Section (Screen, "cli.repo.section.code");
                        end if;
                     end if;
                     for Index in 1 .. Natural (Code_Edges.Length) loop
                        if Verbose or else Index <= 30 then
                           Pres.Put_Indented
                             (Screen, "cli.repo.unit", [Loc.Named ("name", Code_Edges (Index))]);
                        end if;
                     end loop;
                     if not Verbose and then Natural (Code_Edges.Length) > 30 then
                        Pres.Put_Message
                          (Screen, "cli.repo.more",
                           [Loc.Named ("count", Image (Natural (Code_Edges.Length) - 30)),
                            Loc.Named ("name", "edges")]);
                     end if;
                     if Shown.Is_Empty
                       and then (for some Prefix of Model_Runner.Framework.Name_Lists.Vector'(["REQ-", "DEC-", "SPEC-"])
                                   => Ada.Strings.Fixed.Index (Argument, Prefix) = Argument'First)
                       and then Model_Runner.Framework.Intent.State_Of
                                  (Store, Model_Runner.Framework.Intent.Requirement, Argument) = ""
                       and then Model_Runner.Framework.Intent.State_Of
                                  (Store, Model_Runner.Framework.Intent.Decision, Argument) = ""
                       and then Model_Runner.Framework.Intent.State_Of
                                  (Store, Model_Runner.Framework.Intent.Specification, Argument) = ""
                     then
                        --  Not an entry at all: said so, with the code that
                        --  names it all the same.
                        declare
                           Naming : Unbounded_String;
                           Count  : Natural := 0;
                           Read_Already : constant Model_Runner.Framework.Name_Lists.Vector :=
                             Model_Runner.Framework.Bootstrap.Documents (Store);
                           In_Read : Boolean := False;
                        begin
                           for Index in 1 .. Rp.File_Count (Found) loop
                              exit when Count >= 5;
                              declare
                                 Path : constant String := To_String (Rp.File_At (Found, Index).Path);
                                 Text : Unbounded_String;
                                 Read : E.Error_Info := E.Success;
                                 At_Word : Natural;
                              begin
                                 declare
                                    use Ada.Streams.Stream_IO;
                                    File : File_Type;
                                 begin
                                    Open (File, In_File, Hostkit.Fs.Join (Directory, Path));
                                    if Size (File) < 2_000_000 then
                                       declare
                                          Whole : String (1 .. Natural (Size (File)));
                                       begin
                                          String'Read (Stream (File), Whole);
                                          Text := To_Unbounded_String (Whole);
                                       end;
                                    end if;
                                    Close (File);
                                 exception
                                    when others =>
                                       if Is_Open (File) then
                                          Close (File);
                                       end if;
                                       Read := E.Make (E.Framework_Not_Found);
                                 end;
                                 At_Word := (if E.Is_Ok (Read) then Ada.Strings.Unbounded.Index (Text, Argument)
                                             else 0);
                                 if At_Word > 0
                                   and then (At_Word = 1
                                             or else Element (Text, At_Word - 1)
                                                       not in '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z' | '-' | '_')
                                   and then (At_Word + Argument'Length > Length (Text)
                                             or else Element (Text, At_Word + Argument'Length) not in '0' .. '9')
                                 then
                                    Append (Naming, (if Count = 0 then "" else ", ") & Path);
                                    Count := Count + 1;
                                    --  A document bootstrap reads already: reading it
                                    --  again makes no more of it.
                                    if Read_Already.Contains (Path) then
                                       In_Read := True;
                                    end if;
                                 end if;
                              end;
                           end loop;
                           --  A label bootstrap made an entry of: that entry, by
                           --  its own identifier.
                           declare
                              package Nt renames Model_Runner.Framework.Intent;
                              Made_As : Unbounded_String;
                           begin
                              for Kind in Nt.Intent_Kind loop
                                 for Known of Nt.List (Store, Kind) loop
                                    declare
                                       Held : Nt.Entity;
                                       Got  : E.Error_Info;
                                       Mark : Unbounded_String;
                                    begin
                                       Nt.Read (Store, Kind, Known, Held, Got);
                                       Mark := Held.Provenance;
                                       if E.Is_Ok (Got) and then Made_As = Null_Unbounded_String
                                         and then (Ada.Strings.Unbounded.Index (Mark, "#" & Argument) > 0
                                                   and then Ada.Strings.Unbounded.Index (Mark, "#" & Argument)
                                                            + Argument'Length = Length (Mark))
                                       then
                                          Made_As := To_Unbounded_String (Known);
                                       end if;
                                    end;
                                 end loop;
                              end loop;
                              if Made_As /= Null_Unbounded_String then
                                 Pres.Put_Message (Screen, "cli.repo.trace_label_is",
                                                   [Loc.Named ("name", Argument),
                                                    Loc.Named ("value", To_String (Made_As))]);
                                 S.Close (Store);
                                 return;
                              end if;
                           end;
                           Pres.Put_Message (Screen, (if In_Read then "cli.repo.trace_unknown_read"
                                                      else "cli.repo.trace_unknown"),
                                             [Loc.Named ("name", Argument),
                                              Loc.Named ("detail", (if Count = 0 then "nothing in the code names it"
                                                                    elsif Count = 1
                                                                    then To_String (Naming) & " names it"
                                                                    else To_String (Naming) & " name it"))]);
                        end;
                     elsif Shown.Is_Empty then
                        Pres.Put_Message (Screen, "cli.repo.no_edges", [Loc.Named ("name", Argument)]);
                        --  An entry: how a link is made.
                        if (for some Prefix of Model_Runner.Framework.Name_Lists.Vector'
                              (["REQ-", "SPEC-", "DEC-"]) =>
                              Ada.Strings.Fixed.Index (Argument, Prefix) = Argument'First)
                        then
                           Pres.Put_Note (Screen, "cli.next.trace_link",
                                          [Loc.Named ("name", Argument),
                                           Loc.Named
                                             ("value",
                                              (if Ada.Strings.Fixed.Index (Argument, "REQ-") = Argument'First
                                               then "req"
                                               elsif Ada.Strings.Fixed.Index (Argument, "SPEC-") = Argument'First
                                               then "spec" else "decision"))]);
                        end if;
                     end if;

                     --  A requirement the code names -- by its identifier or
                     --  the document's own label -- with no link to that file:
                     --  each such file said, with the link that ties it.
                     if Model_Runner.Framework.Intent.State_Of
                          (Store, Model_Runner.Framework.Intent.Requirement, Argument) /= ""
                     then
                        declare
                           Held  : Model_Runner.Framework.Intent.Entity;
                           Got   : E.Error_Info;
                           Label : Unbounded_String;
                           Said  : Natural := 0;
                        begin
                           Model_Runner.Framework.Intent.Read
                             (Store, Model_Runner.Framework.Intent.Requirement, Argument, Held, Got);
                           --  The label is the end of where it was read from.
                           if E.Is_Ok (Got)
                             and then Ada.Strings.Fixed.Index (To_String (Held.Provenance), "#", Ada.Strings.Backward)
                                      > 0
                           then
                              declare
                                 Source : constant String := To_String (Held.Provenance);
                                 Hash   : constant Natural :=
                                   Ada.Strings.Fixed.Index (Source, "#", Ada.Strings.Backward);
                              begin
                                 if Hash < Source'Last and then Source (Hash + 1 .. Source'Last) /= "retired" then
                                    Label := To_Unbounded_String (Source (Hash + 1 .. Source'Last));
                                 end if;
                              end;
                           end if;
                           for Index in 1 .. Rp.File_Count (Found) loop
                              exit when Said >= 10;
                              declare
                                 Path : constant String := To_String (Rp.File_At (Found, Index).Path);
                                 Text : Unbounded_String;
                                 Read : E.Error_Info := E.Success;
                                 --  Named as a whole word: FR-1 is not in NFR-1,
                                 --  nor REQ-1 in REQ-10.
                                 function Names_It (Word : String) return Boolean is
                                    From : Positive := 1;
                                 begin
                                    if Word = "" then
                                       return False;
                                    end if;
                                    loop
                                       declare
                                          At_Word : constant Natural :=
                                            Ada.Strings.Unbounded.Index (Text, Word, From);
                                       begin
                                          exit when At_Word = 0;
                                          if (At_Word = 1
                                              or else Element (Text, At_Word - 1)
                                                        not in '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z' | '-' | '_')
                                            and then (At_Word + Word'Length > Length (Text)
                                                      or else Element (Text, At_Word + Word'Length)
                                                                not in '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z')
                                          then
                                             return True;
                                          end if;
                                          From := At_Word + 1;
                                       end;
                                    end loop;
                                    return False;
                                 end Names_It;
                                 --  A document is where requirements are said, not
                                 --  where they are done: no implementation.
                                 Is_Document : constant Boolean :=
                                   Rp."=" (Rp.File_At (Found, Index).Role, Rp.Documentation)
                                   or else (for some Ext of Model_Runner.Framework.Name_Lists.Vector'
                                              ([".md", ".adoc", ".rst", ".txt"]) =>
                                              Path'Length > Ext'Length
                                              and then Path (Path'Last - Ext'Length + 1 .. Path'Last) = Ext);
                                 Linked : Boolean := False;
                              begin
                                 for Line of Shown loop
                                    Linked := Linked or else Ada.Strings.Fixed.Index (Line, "file:" & Path) > 0;
                                 end loop;
                                 if not Linked and then not Is_Document
                                   and then Ada.Directories.Exists (Hostkit.Fs.Join (Directory, Path))
                                   and then Ada.Directories."<"
                                              (Ada.Directories.Size (Hostkit.Fs.Join (Directory, Path)), 2_000_000)
                                 then
                                    declare
                                       use Ada.Streams.Stream_IO;
                                       File : File_Type;
                                    begin
                                       Open (File, In_File, Hostkit.Fs.Join (Directory, Path));
                                       declare
                                          Whole : String (1 .. Natural (Size (File)));
                                       begin
                                          String'Read (Stream (File), Whole);
                                          Text := To_Unbounded_String (Whole);
                                       end;
                                       Close (File);
                                    exception
                                       when others =>
                                          if Is_Open (File) then
                                             Close (File);
                                          end if;
                                          Read := E.Make (E.Framework_Not_Found);
                                    end;
                                    if E.Is_Ok (Read)
                                      and then (Names_It (Argument) or else Names_It (To_String (Label)))
                                    then
                                       Said := Said + 1;
                                       --  Named by the document's label only: said by it.
                                       Pres.Put_Note
                                         (Screen, (if Names_It (Argument) then "cli.repo.mentioned"
                                                   else "cli.repo.mentioned_label"),
                                          [Loc.Named ("name", Path), Loc.Named ("value", Argument),
                                           Loc.Named ("other", To_String (Label)),
                                           Loc.Named ("detail",
                                                      (if Ada.Strings.Fixed.Index
                                                            (Ada.Characters.Handling.To_Lower (Path), "test") > 0
                                                       then "test" else "implementation"))]);
                                    end if;
                                 end if;
                              exception
                                 when others =>
                                    null;
                              end;
                           end loop;
                        end;
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

                     --  In groups, each under its title: what changes, what it
                     --  reaches, and the tests to run.
                     Pres.Put_Header (Screen, "cli.repo.section.changes");
                     for Index in 1 .. Natural (Changed.Length) loop
                        exit when not Verbose and then Index > 10;
                        Pres.Put_Indented (Screen, "cli.repo.unit",
                                          [Loc.Named ("name", Changed (Index))]);
                     end loop;
                     if not Verbose and then Natural (Changed.Length) > 10 then
                        Pres.Put_Message (Screen, "cli.repo.more",
                                          [Loc.Named ("count", Image (Natural (Changed.Length) - 10)),
                                           Loc.Named ("name", "changed")]);
                     end if;
                     Pres.Put_Section (Screen, "cli.repo.section.reaches");
                     --  What matters first first: requirements, tasks and
                     --  tests before files and symbols; a long run of one
                     --  kind cut to its first ten unless asked for whole.
                     declare
                        Order  : constant Model_Runner.Framework.Name_Lists.Vector :=
                          ["requirement", "task", "test", "specification", "decision",
                           "component", "file", "unit", "symbol", "other"];
                        Counts : Unbounded_String;
                        Counted : Natural := 0;

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
                        --  A requirement the file names -- its identifier, or its
                        --  document's label -- reached whether or not the code
                        --  graph links them.
                        if Ada.Directories.Exists (Argument) then
                           declare
                              Text : Unbounded_String;
                              File : Ada.Text_IO.File_Type;
                              Read_Files : Natural := 0;

                              --  A file's lines, or a directory's files' -- what
                              --  is under a directory names its requirements too.
                              procedure Take (Path : String; Depth : Natural) is
                                 use Ada.Directories;
                              begin
                                 if Kind (Path) = Ada.Directories.Directory then
                                    if Depth = 0 then
                                       return;
                                    end if;
                                    declare
                                       Search : Search_Type;
                                       Next   : Directory_Entry_Type;
                                       Below  : Model_Runner.Framework.Name_Lists.Vector;
                                    begin
                                       Start_Search (Search, Path, "");
                                       while More_Entries (Search) loop
                                          Get_Next_Entry (Search, Next);
                                          if Simple_Name (Next) (Simple_Name (Next)'First) /= '.' then
                                             Below.Append (Full_Name (Next));
                                          end if;
                                       end loop;
                                       End_Search (Search);
                                       for One of Below loop
                                          Take (One, Depth - 1);
                                       end loop;
                                    end;
                                 elsif Read_Files < 200 and then Size (Path) < 1_000_000 then
                                    Read_Files := Read_Files + 1;
                                    Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
                                    while not Ada.Text_IO.End_Of_File (File) loop
                                       Append (Text, Ada.Text_IO.Get_Line (File) & ASCII.LF);
                                    end loop;
                                    Ada.Text_IO.Close (File);
                                 end if;
                              exception
                                 when others =>
                                    if Ada.Text_IO.Is_Open (File) then
                                       Ada.Text_IO.Close (File);
                                    end if;
                              end Take;
                           begin
                              Take (Argument, 5);
                              for Req of Model_Runner.Framework.Intent.List
                                           (Store, Model_Runner.Framework.Intent.Requirement)
                              loop
                                 declare
                                    Held : Model_Runner.Framework.Intent.Entity;
                                    Read : E.Error_Info;
                                    Whole : Unbounded_String;
                                    Label : Unbounded_String;
                                 begin
                                    Model_Runner.Framework.Intent.Read
                                      (Store, Model_Runner.Framework.Intent.Requirement, Req, Held, Read);
                                    Whole := Held.Provenance;
                                    if Ada.Strings.Unbounded.Index (Whole, "#") > 0 then
                                       Label := Unbounded_Slice
                                         (Whole, Ada.Strings.Unbounded.Index (Whole, "#") + 1, Length (Whole));
                                    end if;
                                    if not Ids.Contains ("requirement:" & Req) and then not Ids.Contains (Req)
                                      and then E.Is_Ok (Read)
                                      and then To_String (Held.State) not in "rejected" | "obsolete" | "superseded"
                                      and then (Ada.Strings.Unbounded.Index (Text, Req) > 0
                                                or else (Length (Label) in 3 .. 11
                                                         and then Ada.Strings.Unbounded.Index
                                                                    (Text, To_String (Label)) > 0))
                                    then
                                       Ids.Append (Req);
                                       All_Reached.Append
                                         (Tr.Reached'(Kind => To_Unbounded_String ("requirement"),
                                                      Id   => To_Unbounded_String (Req),
                                                      Sure => Rp.Certain));
                                    end if;
                                 end;
                              end loop;
                           exception
                              when others =>
                                 if Ada.Text_IO.Is_Open (File) then
                                    Ada.Text_IO.Close (File);
                                 end if;
                           end;
                        end if;
                        for Kind of Order loop
                           declare
                              Of_Kind : Natural := 0;
                              --  Requirements and tasks reached only by sharing
                              --  a component with it: one line, not one each.
                              Shared  : Unbounded_String;
                              Shared_Count : Natural := 0;
                              Listed_Ids   : Model_Runner.Framework.Name_Lists.Vector;

                              --  Whether the file changed names a requirement:
                              --  its identifier, or its document's label.
                              function Named_In_File (Id : String) return Boolean is
                                 Text : Unbounded_String;
                                 Held : Model_Runner.Framework.Intent.Entity;
                                 Read : E.Error_Info;
                              begin
                                 if Kind /= "requirement" or else not Ada.Directories.Exists (Argument) then
                                    return False;
                                 end if;
                                 declare
                                    File : Ada.Text_IO.File_Type;
                                 begin
                                    Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Argument);
                                    while not Ada.Text_IO.End_Of_File (File) loop
                                       Append (Text, Ada.Text_IO.Get_Line (File) & ASCII.LF);
                                    end loop;
                                    Ada.Text_IO.Close (File);
                                 end;
                                 if Ada.Strings.Unbounded.Index (Text, Id) > 0 then
                                    return True;
                                 end if;
                                 Model_Runner.Framework.Intent.Read
                                   (Store, Model_Runner.Framework.Intent.Requirement, Id, Held, Read);
                                 if E.Is_Ok (Read) and then Ada.Strings.Unbounded.Index (Held.Provenance, "#") > 0
                                 then
                                    declare
                                       Whole : constant String := To_String (Held.Provenance);
                                       Label : constant String :=
                                         Whole (Ada.Strings.Fixed.Index (Whole, "#") + 1 .. Whole'Last);
                                    begin
                                       return Label'Length >= 3 and then Label'Length < 12
                                         and then Ada.Strings.Unbounded.Index (Text, Label) > 0;
                                    end;
                                 end if;
                                 return False;
                              exception
                                 when others =>
                                    return False;
                              end Named_In_File;
                           begin
                              for One of All_Reached loop
                                 --  One entry reached two ways -- by its label
                                 --  and its identifier, as its source and named
                                 --  in it -- is one: listed and counted once.
                                 if To_String (One.Kind) = Kind then
                                    if Listed_Ids.Contains (Bare_Id (To_String (One.Id))) then
                                       goto Next_Reached;
                                    end if;
                                    Listed_Ids.Append (Bare_Id (To_String (One.Id)));
                                 end if;
                                 if not Verbose and then To_String (One.Kind) = Kind
                                   and then Kind in "requirement" | "task"
                                   and then Rp."=" (One.Sure, Rp.Probable)
                                   and then not Named_In_File (Bare_Id (To_String (One.Id)))
                                 then
                                    Append (Shared, (if Shared = Null_Unbounded_String then "" else " ")
                                            & Bare_Id (To_String (One.Id)));
                                    Shared_Count := Shared_Count + 1;
                                    Of_Kind := Of_Kind + 1;
                                    goto Next_Reached;
                                 end if;
                                 begin
                                    if To_String (One.Kind) = Kind then
                                       Of_Kind := Of_Kind + 1;
                                       if Verbose or else Of_Kind <= 10 then
                                          Pres.Put_Indented
                                            (Screen, "cli.repo.reached",
                                             [Loc.Named ("value", Kind),
                                              Loc.Named ("name", (if Verbose then To_String (One.Id)
                                                                  else Node_Said (To_String (One.Id)))),
                                              Loc.Named ("detail",
                                                         (if Kind = "requirement"
                                                            and then Named_In_File (Bare_Id (To_String (One.Id)))
                                                          then "named in it"
                                                          elsif Verbose or else Rp."/=" (One.Sure, Rp.Certain)
                                                          then Ada.Characters.Handling.To_Lower
                                                                 (Rp.Confidence'Image (One.Sure))
                                                          else ""))]);
                                       end if;
                                    end if;
                                 end;
                                 <<Next_Reached>>
                              end loop;
                              if Shared_Count > 0 then
                                 Pres.Put_Indented
                                   (Screen, "cli.repo.reached",
                                    [Loc.Named ("value", Kind),
                                     Loc.Named ("name", To_String (Shared)),
                                     Loc.Named ("detail", "probable: by sharing its component")]);
                              end if;
                              if not Verbose and then Of_Kind > 10 then
                                 Pres.Put_Message
                                   (Screen, "cli.repo.more",
                                    [Loc.Named ("count", Image (Of_Kind - 10)),
                                     Loc.Named ("name", Kind)]);
                              end if;
                              if Of_Kind > 0 then
                                 Append (Counts, (if Counts = Null_Unbounded_String then "" else ", ")
                                         & Kind & ": " & Image (Of_Kind));
                                 Counted := Counted + Of_Kind;
                              end if;
                           end;
                        end loop;
                        Pres.Put_Indented
                          (Screen, "cli.repo.impact_summary",
                           [Loc.Named ("name", (if Argument = "" then "the project" else Argument)),
                            --  What was counted above, so the sum adds up.
                            Loc.Named ("count", Image (Counted)),
                            Loc.Named ("detail", To_String (Counts))]);
                     end;
                     Chosen := Tr.Select_Tests (Store, Reach);
                     Pres.Put_Section (Screen, "cli.repo.section.tests");
                     Pres.Put_Indented
                       (Screen, "cli.repo.selection",
                        [Loc.Named ("value",
                                    (case Chosen.Width is
                                        when Tr.Full_Suite      => "the whole suite",
                                        when Tr.Component_Tests => "its component's tests",
                                        when Tr.Certain_Tests   => "the tests it certainly reaches")),
                         Loc.Named ("detail", To_String (Chosen.Reason))]);
                     --  The tests themselves, where only some are to run.
                     if Tr."/=" (Chosen.Width, Tr.Full_Suite) then
                        for Test of Chosen.Tests loop
                           Pres.Put_Indented (Screen, "cli.repo.unit", [Loc.Named ("name", Test)], Indent => 4);
                        end loop;
                     end if;
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
            --  What the list is, as its title.
            elsif not Units.Is_Empty then
               Pres.Put_Header (Screen, (if Action = "users" then "cli.repo.users_of" else "cli.repo.deps_of"),
                                [Loc.Named ("name", Argument)]);
            end if;
            for Unit of Units loop
               Pres.Put_Indented
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
