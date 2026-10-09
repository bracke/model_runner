separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Bootstrap (Store : in out S.Store) is
   Change : S.Transaction;
   Found  : Model_Runner.Framework.Bootstrap.Output_List;
   Report : Model_Runner.Framework.Bootstrap.Report;
   --  Each named as the project names it: ./docs/x.md and a whole
   --  path into the project are docs/x.md.
   --  A directory named is its Markdown files; one named twice is
   --  read once.
   function Named_Here return Names.Vector is
      Result : Names.Vector;
      procedure Add (One : String) is
      begin
         if not Result.Contains (One) then
            Result.Append (One);
         end if;
      end Add;

      --  Whether a path matches a pattern: * any characters but /,
      --  ** any directories, none among them.
      function Matches (Pattern, Path : String) return Boolean is
      begin
         if Pattern = "" then
            return Path = "";
         elsif Pattern'Length >= 3 and then Pattern (Pattern'First .. Pattern'First + 2) = "**/" then
            if Matches (Pattern (Pattern'First + 3 .. Pattern'Last), Path) then
               return True;
            end if;
            for Cut in Path'Range loop
               if Path (Cut) = '/'
                 and then Matches (Pattern (Pattern'First + 3 .. Pattern'Last), Path (Cut + 1 .. Path'Last))
               then
                  return True;
               end if;
            end loop;
            return False;
         elsif Pattern (Pattern'First) = '*' then
            for Skip in 0 .. Path'Length loop
               exit when Skip > 0 and then Path (Path'First + Skip - 1) = '/';
               if Matches (Pattern (Pattern'First + 1 .. Pattern'Last), Path (Path'First + Skip .. Path'Last))
               then
                  return True;
               end if;
            end loop;
            return False;
         elsif Path = "" then
            return False;
         elsif Pattern (Pattern'First) = Path (Path'First) then
            return Matches (Pattern (Pattern'First + 1 .. Pattern'Last), Path (Path'First + 1 .. Path'Last));
         end if;
         return False;
      end Matches;

      --  The files under a directory ("" the project's), each a
      --  document, or each the pattern matches: built output, the
      --  state and what a dot hides left out.
      procedure Walk (Dir, Pattern : String) is
         Search : Ada.Directories.Search_Type;
         One    : Ada.Directories.Directory_Entry_Type;
         Below  : Names.Vector;
      begin
         Ada.Directories.Start_Search (Search, (if Dir = "" then "." else Dir), "");
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, One);
            declare
               Simple : constant String := Ada.Directories.Simple_Name (One);
               Lower  : constant String := Ada.Characters.Handling.To_Lower (Simple);
               Path   : constant String := (if Dir = "" then Simple else Dir & "/" & Simple);
            begin
               if Simple (Simple'First) = '.'
                 or else Lower in "obj" | "bin" | "alire" | "node_modules" | "target" | "build" | "_build"
                                | "__pycache__" | "venv" | "dist"
               then
                  null;
               elsif Ada.Directories."=" (Ada.Directories.Kind (One), Ada.Directories.Directory) then
                  Below.Append (Path);
               elsif (if Pattern /= "" then Matches (Pattern, Path)
                      else (for some Ending of Names.Vector'([".md", ".txt", ".rst", ".adoc"]) =>
                              Lower'Length > Ending'Length
                              and then Lower (Lower'Last - Ending'Length + 1 .. Lower'Last) = Ending))
               then
                  Add (Path);
               end if;
            end;
         end loop;
         Ada.Directories.End_Search (Search);
         for Next of Below loop
            Walk (Next, Pattern);
         end loop;
      end Walk;
   begin
      for Path of Positional loop
         declare
            --  Where the session was started, below the project's
            --  top: a name is from there first, as Tab and /impact
            --  take it -- a pattern is the whole project's.
            From_Below : constant String :=
              (if Started_Below /= "" and then Path /= "" and then Path (Path'First) /= '/'
                 and then Ada.Strings.Fixed.Index (Path, "*") = 0
                 and then Ada.Directories.Exists (Hostkit.Fs.Join (Started_Below, Path))
               then Ada.Directories.Full_Name (Hostkit.Fs.Join (Started_Below, Path))
               --  A pattern up from there -- ../../docs/*.md -- from there too.
               elsif Started_Below /= "" and then Ada.Strings.Fixed.Head (Path, 3) = "../"
               then Ada.Directories.Full_Name (Hostkit.Fs.Join (Started_Below, Path))
               else Path);
            Here : constant String := Model_Runner.Framework.Repository.Relative_Path
                                        (Ada.Directories.Current_Directory, From_Below);
         begin
            --  A pattern -- docs/*.md, docs/**/*.rst, **/*.md -- the
            --  files it matches anywhere in the project; a directory --
            --  . for the whole project -- the documents in it and below.
            if Ada.Strings.Fixed.Index (Here, "*") > 0 then
               Walk ("", Here);
            elsif Here in "" | "." | "./"
              or else (Ada.Directories.Exists (Here)
                       and then Ada.Directories."=" (Ada.Directories.Kind (Here), Ada.Directories.Directory))
            then
               Walk ((if Here in "" | "." | "./" then ""
                      elsif Here (Here'Last) = '/' then Here (Here'First .. Here'Last - 1) else Here),
                     "");
            else
               Add (Here);
            end if;
         end;
      end loop;
      return Result;
   end Named_Here;
   Named : constant Names.Vector := Named_Here;

   --  The directories the policy would have read from and could not:
   --  said, so what is imported is not taken for all there is.
   Unread : Names.Vector;

   function Policy_Documents return Names.Vector is
      Found : Names.Vector;
   begin
      Model_Runner.Framework.Bootstrap.List_Documents (Store, "", Found, Unread);
      return Found;
   end Policy_Documents;

   --  The documents named, or those the bootstrap policy reads.
   Files  : constant Names.Vector :=
     (if Positional.Is_Empty then Policy_Documents else Named);
begin
   for Directory of Unread loop
      Pres.Put_Note (Screen, "cli.bootstrap.unread", [Loc.Named ("path", Directory)]);
   end loop;
   --  A pattern that finds nothing is said, not read as a name.
   for Path of Positional loop
      if Ada.Strings.Fixed.Index (Path, "*") > 0 and then Named.Is_Empty then
         Outcome := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Outcome, "name", "a document to read");
         E.Add_Text (Outcome, "value", Path);
         E.Add_Text (Outcome, "detail", "no file matches it");
         Pres.Report (Screen, Outcome);
         return;
      end if;
   end loop;
   --  A document named is one within the project, outside its state,
   --  and there to be read: nothing is taken from one that is not.
   for Path of Named loop
      declare
         Extension : constant String :=
           Ada.Characters.Handling.To_Lower (Ada.Directories.Extension (Path));
      begin
         --  Source is not a document: what it must do is read from
         --  prose, not guessed from code.
         if Extension not in "" | "md" | "markdown" | "txt" | "text" | "rst" | "adoc" | "asciidoc" | "org"
         then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "a document to read");
            E.Add_Text (Outcome, "value", Path);
            E.Add_Text (Outcome, "detail",
                        "/bootstrap reads Markdown and text (.md, .txt, .rst, .adoc, .org)"
                        & (if Extension in "yaml" | "yml" | "json" | "toml" | "csv" | "pdf" | "docx" | "odt"
                           then ", not ." & Extension & ": what it holds is said by hand -- /req new TITLE"
                                & " text=... for each requirement, or a Markdown list of them is read"
                           else "; what code does is found with /scan and /sym"));
            Pres.Report (Screen, Outcome);
            return;
         end if;
      end;
   end loop;
   for Path of Named loop
      if Path = "" or else Path (Path'First) in '/' | '\'
        or else Ada.Strings.Fixed.Index (Path, "..") > 0
        or else Ada.Strings.Fixed.Index (Path, ".model_runner") > 0
        or else not Ada.Directories.Exists (Path)
        or else Ada.Directories."/=" (Ada.Directories.Kind (Path), Ada.Directories.Ordinary_File)
      then
         Outcome := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Outcome, "name", "a document to read");
         E.Add_Text (Outcome, "value", Path);
         E.Add_Text (Outcome, "detail",
                     (if not Ada.Directories.Exists (Path) then "there is no such file"
                      elsif Ada.Strings.Fixed.Index (Path, ".model_runner") > 0
                      then "it is the project's own state, not a document of the project's"
                      else "it lies outside the project, which is "
                           & Ada.Directories.Containing_Directory (S.Root (Store))
                           & " -- copy it in, or /init where the whole of it is"));
         Pres.Report (Screen, Outcome);
         return;
      end if;
   end loop;
   for Path of Files loop
      declare
         Text : Unbounded_String;
         Read : E.Error_Info;
      begin
         --  A document that would not read is said, not scanned as
         --  one with nothing in it.
         Read_Whole (Path, Text, Read);
         if E.Is_Error (Read) then
            Pres.Report (Screen, Read);
            return;
         end if;
         declare
            Scanned : constant Model_Runner.Framework.Bootstrap.Output_List :=
              Model_Runner.Framework.Bootstrap.Scan (Path, To_String (Text));
         begin
            for Index in 1 .. Model_Runner.Framework.Bootstrap.Length (Scanned) loop
               Model_Runner.Framework.Bootstrap.Append
                 (Found, Model_Runner.Framework.Bootstrap.Element (Scanned, Index));
            end loop;
         end;
      end;
   end loop;
   if Files.Is_Empty then
      declare
         Config : R.Item;
         Shown  : Unbounded_String;
      begin
         Config := Model_Runner.Framework.Configurations.Required (Store);
         for One of Model_Runner.Framework.Lines_Of
           (Ada.Strings.Fixed.Translate (R.Get (Config, "set.bootstrap.sources"),
                                         Ada.Strings.Maps.To_Mapping (", ", [ASCII.LF, ASCII.LF])))
         loop
            Append (Shown, (if Shown = Null_Unbounded_String then "" else ", ") & One);
         end loop;
         Pres.Put_Note (Screen, "cli.next.no_documents",
                        [Loc.Named ("detail", (if Shown = Null_Unbounded_String then "*.md, docs/**/*.md"
                                               else To_String (Shown)))]);
      end;
      return;
   end if;
   --  Items the documents number are theirs, accepted as the documents
   --  have them -- asked first at a terminal, where the project has
   --  not said, as they govern once accepted.
   declare
      package Bt renames Model_Runner.Framework.Bootstrap;
      Numbered : Names.Vector;
      Accepting : Boolean := True;
      Config    : R.Item;
   begin
      Config := Model_Runner.Framework.Configurations.Required (Store);
      for Index in 1 .. Bt.Length (Found) loop
         declare
            One : constant Bt.Output := Bt.Element (Found, Index);
         begin
            if Bt."=" (One.Kind, Bt.Imported_Item)
              and then Length (One.Given_Id) > 0
              and then not S.Exists (Store, Model_Runner.Framework.Requirements_Area,
                                     To_String (One.Given_Id))
              and then Model_Runner.Framework.Intent.Find_By_Provenance
                         (Store, Nt.Requirement, To_String (One.Provenance)) = ""
            then
               Numbered.Append (To_String (One.Given_Id));
            end if;
         end;
      end loop;
      if not Numbered.Is_Empty and then R.Get (Config, "scalar.bootstrap.import") = ""
        and then Model_Runner.CLI.Choosers.Is_Available (Screen)
      then
         declare
            Listed : Unbounded_String;
         begin
            for Id of Numbered loop
               Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & Id);
            end loop;
            Pres.Put_Message (Screen, "cli.project.bootstrap.numbered",
                              [Loc.Named ("count", Image (Natural (Numbered.Length))),
                               Loc.Named ("detail", To_String (Listed))]);
            Accepting := Answered_Yes (Screen);
         end;
      end if;
      Bt.Apply (Store, Change, Found, Report, Outcome, Accept_Numbered => Accepting,
                Only_Read => not Named.Is_Empty);
   end;
   if E.Is_Ok (Outcome) then
      S.Commit (Store, Change, Outcome);
   end if;
   if E.Is_Error (Outcome) then
      Pres.Report (Screen, Outcome);
      return;
   end if;
   Pres.Put_Message
     (Screen, "cli.project.bootstrapped",
      [Loc.Named ("count", Image (Report.Created)),
       Loc.Named ("value", Image (Natural (Report.Revised.Length))),
       Loc.Named ("total", Image (Report.Existing)),
       Loc.Named ("index", Image (Report.Rejected)),
       Loc.Named ("extra", Image (Report.Issues))]);
   --  Each with what it is now: a candidate waits to be accepted. Many
   --  are said as runs -- REQ-X-001 .. REQ-X-318 -- of one state.
   declare
      function Kind_Of (Id : String) return Nt.Intent_Kind
      is (if Ada.Strings.Fixed.Index (Id, "DEC-") = 1 then Nt.Decision
          elsif Ada.Strings.Fixed.Index (Id, "SPEC-") = 1 then Nt.Specification
          else Nt.Requirement);

      function Stem (Id : String) return String is
         Dash : constant Natural := Ada.Strings.Fixed.Index (Id, "-", Ada.Strings.Backward);
      begin
         return (if Dash = 0 then Id else Id (Id'First .. Dash));
      end Stem;

      function Number_In (Id : String) return Natural is
         Dash : constant Natural := Ada.Strings.Fixed.Index (Id, "-", Ada.Strings.Backward);
      begin
         return Natural'Value (Id (Dash + 1 .. Id'Last));
      exception
         when others =>
            return 0;
      end Number_In;

      First_Of : Unbounded_String;
      Last_Of  : Unbounded_String;
      Count    : Natural := 0;

      --  Whether any was accepted at once: why, said once after.
      Accepted_At_Once : Boolean := False;

      --  A state as made, marked where it was accepted at once.
      function Made_As (Id : String) return String is
         State : constant String := Nt.State_Of (Store, Kind_Of (Id), Id);
      begin
         if State = Tk.Accepted then
            Accepted_At_Once := True;
         end if;
         return (if State = Tk.Accepted then "accepted at once" else State);
      end Made_As;

      procedure Say_Run is
      begin
         if Count = 1 then
            --  One alone, by its title too: what it is, not just its number.
            declare
               Held : Nt.Entity;
               Got  : E.Error_Info;
            begin
               Nt.Read (Store, Kind_Of (To_String (First_Of)), To_String (First_Of), Held, Got);
               Pres.Put_Message
                 (Screen, "cli.project.bootstrap.made",
                  [Loc.Named ("name", To_String (First_Of)
                                      & (if E.Is_Ok (Got) and then Length (Held.Title) > 0
                                         then " """ & To_String (Held.Title) & """" else "")),
                   Loc.Named ("value", Made_As (To_String (First_Of)))]);
            end;
         elsif Count > 1 then
            Pres.Put_Message
              (Screen, "cli.project.bootstrap.made",
               [Loc.Named ("name", To_String (First_Of) & " .. " & To_String (Last_Of)
                                   & " (" & Image (Count) & ")"),
                Loc.Named ("value", Made_As (To_String (First_Of)))]);
         end if;
         Count := 0;
      end Say_Run;
   begin
      for Id of Report.Made loop
         if Natural (Report.Made.Length) > 12 and then Count > 0
           and then Stem (Id) = Stem (To_String (First_Of))
           --  A run is numbers that follow one another: one taken out
           --  of it and said apart is not in it.
           and then Number_In (Id) = Number_In (To_String (Last_Of)) + 1
           and then Nt.State_Of (Store, Kind_Of (Id), Id)
                    = Nt.State_Of (Store, Kind_Of (To_String (First_Of)), To_String (First_Of))
         then
            Last_Of := To_Unbounded_String (Id);
            Count := Count + 1;
         else
            Say_Run;
            First_Of := To_Unbounded_String (Id);
            Last_Of := First_Of;
            Count := 1;
         end if;
      end loop;
      Say_Run;
      if Accepted_At_Once then
         Pres.Put_Note (Screen, "cli.project.bootstrap.accepted_why");
      end if;
   end;
   for Line of Report.Moved loop
      Pres.Put_Message (Screen, "cli.project.bootstrap.moved", [Loc.Named ("detail", Line)]);
   end loop;
   for Line of Report.Adopted loop
      Pres.Put_Message (Screen, "cli.project.bootstrap.adopted", [Loc.Named ("detail", Line)]);
   end loop;
   for Id of Report.Revised loop
      Pres.Put_Message (Screen, "cli.project.bootstrap.revised", [Loc.Named ("name", Id)]);
      --  Work done or doing for what it said before: named.
      declare
         Serving : Unbounded_String;
      begin
         for Task_Id of Tk.List (Store) loop
            declare
               Defined : R.Item;
               Got     : E.Error_Info;
            begin
               Tk.Definition (Store, Task_Id, Defined, Got);
               if E.Is_Ok (Got)
                 and then Tk.State_Of (Store, Task_Id) not in "cancelled" | "rejected"
                 and then Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"))
                            .Contains (Id)
               then
                  Append (Serving, (if Serving = Null_Unbounded_String then "" else ", ")
                                   & Task_Id);
               end if;
            end;
         end loop;
         if Serving /= Null_Unbounded_String then
            Pres.Put_Note (Screen, "cli.project.bootstrap.revised_served",
                           [Loc.Named ("name", Id), Loc.Named ("detail", To_String (Serving))]);
         end if;
      end;
   end loop;
   for Line of Report.Stale loop
      declare
         Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ": ");
      begin
         Pres.Put_Message
           (Screen, "cli.project.bootstrap.stale",
            [Loc.Named ("detail", (if Colon = 0 then Line
                                   else Issue_Said (Store, Line (Line'First .. Colon - 1), Line)))]);
      end;
   end loop;

   --  What it imported as accepted is followed as any accepted
   --  requirement is: its tasks derived, readiness worked out -- its
   --  next step said once, with bootstrap's own.
   Pres.Hold_Next_Steps (Screen, True);
   Model_Runner.CLI.Intents.Move_Along (Store, Screen);
   Pres.Hold_Next_Steps (Screen, False);
   --  Nothing read from what was named: said, with how a document
   --  says a requirement.
   if Report.Created = 0 and then Report.Existing = 0 and then Report.Revised.Is_Empty
     and then Report.Issues = 0 and then Report.Adopted.Is_Empty
   then
      declare
         Listed  : Unbounded_String;
         Retired : Natural := 0;

         --  A decision record that says of itself it is no longer in
         --  force: read, and not proposed, which is not nothing.
         function Retired_Record (Path : String) return Boolean is
            File : Ada.Text_IO.File_Type;
            Seen : Boolean := False;
         begin
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
            while not Ada.Text_IO.End_Of_File (File) and then not Seen loop
               declare
                  Line : constant String :=
                    Ada.Characters.Handling.To_Lower (Ada.Text_IO.Get_Line (File));
               begin
                  Seen := Ada.Strings.Fixed.Index (Line, "status") > 0
                    and then (Ada.Strings.Fixed.Index (Line, "rejected") > 0
                              or else Ada.Strings.Fixed.Index (Line, "deprecated") > 0
                              or else Ada.Strings.Fixed.Index (Line, "superseded") > 0);
               end;
            end loop;
            Ada.Text_IO.Close (File);
            return Seen;
         exception
            when others =>
               if Ada.Text_IO.Is_Open (File) then
                  Ada.Text_IO.Close (File);
               end if;
               return False;
         end Retired_Record;
      begin
         for One of Files loop
            Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & One);
            if Retired_Record (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (S.Root (Store)), One))
            then
               Retired := Retired + 1;
            end if;
         end loop;
         if Retired > 0 and then Retired = Natural (Files.Length) then
            Pres.Put_Note (Screen, "cli.next.bootstrap_retired",
                           [Loc.Named ("count", Image (Retired)), Loc.Named ("detail", To_String (Listed))]);
         else
            Pres.Put_Note (Screen, "cli.next.bootstrap_nothing",
                           [Loc.Named ("detail", To_String (Listed))]);
         end if;
      end;
   end if;

   --  A candidate requirement made waits to be accepted; with none
   --  read at all, how a document says one.
   --  A file an entry is linked to that is gone -- moved, renamed --
   --  said here too, with where git says it went, as /scan says it.
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

   --  Documents that look like requirements or decisions where the
   --  sources do not reach: named, with what reads them.
   declare
      Read_Ones : constant Names.Vector := Model_Runner.Framework.Bootstrap.Documents (Store);
      Unread    : Names.Vector;
      --  Requirements in a form it does not read: YAML, JSON.
      Unreadable : Names.Vector;

      --  A document that has a heading of requirements, or labels
      --  them REQ-: read for that in its first lines.
      function Says_Requirements (Whole : String) return Boolean is
         File  : Ada.Text_IO.File_Type;
         Lines : Natural := 0;
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Whole);
         while not Ada.Text_IO.End_Of_File (File) and then Lines < 200 loop
            declare
               Line  : constant String := Ada.Text_IO.Get_Line (File);
               Lower : constant String := Ada.Characters.Handling.To_Lower (Line);
            begin
               Lines := Lines + 1;
               if (Line'Length > 2 and then Line (Line'First) in '#' | '='
                   and then Ada.Strings.Fixed.Index (Lower, "requirement") > 0)
                 or else Ada.Strings.Fixed.Index (Line, "REQ-") > 0
                 --  A table of them: | ID | Requirement |.
                 or else (Line'Length > 2 and then Line (Line'First) = '|'
                          and then Ada.Strings.Fixed.Index (Lower, "requirement") > 0)
                 --  A list of them: a SHALL said in a list item.
                 or else (Line'Length > 2 and then Line (Line'First) in '-' | '*' | '|'
                          and then Ada.Strings.Fixed.Index (Lower, " shall ") > 0)
               then
                  Ada.Text_IO.Close (File);
                  return True;
               end if;
            end;
         end loop;
         Ada.Text_IO.Close (File);
         return False;
      exception
         when others =>
            if Ada.Text_IO.Is_Open (File) then
               Ada.Text_IO.Close (File);
            end if;
            return False;
      end Says_Requirements;

      procedure Look (Under, Relative : String; Depth : Natural) is
         use Ada.Directories;
         Search : Search_Type;
         Next   : Directory_Entry_Type;
      begin
         Start_Search (Search, Under, "");
         while More_Entries (Search) loop
            Get_Next_Entry (Search, Next);
            declare
               Name  : constant String := Simple_Name (Next);
               Path  : constant String := (if Relative = "" then Name else Relative & "/" & Name);
               Lower : constant String := Ada.Characters.Handling.To_Lower (Name);
            begin
               if Name (Name'First) = '.' or else Name in "node_modules" | "target" | "obj" | "bin" | "alire"
                                                        | "build" | "dist" | "venv"
               then
                  null;
               elsif Kind (Next) = Directory then
                  if Depth > 0 and then not Exists (Hostkit.Fs.Join (Full_Name (Next), ".model_runner")) then
                     Look (Full_Name (Next), Path, Depth - 1);
                  end if;
               elsif Kind (Next) = Ordinary_File
                 and then (Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Path), "requirement") > 0
                           or else Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Path), "spec") > 0
                           or else Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Path), "doc") = 1)
                 and then (for some Ending of Names.Vector'([".yaml", ".yml", ".json", ".toml", ".csv", ".pdf",
                                                              ".docx", ".odt"]) =>
                             Lower'Length > Ending'Length
                             and then Lower (Lower'Last - Ending'Length + 1 .. Lower'Last) = Ending)
                 and then Natural (Unreadable.Length) < 5
               then
                  Unreadable.Append (Path);
               elsif Kind (Next) = Ordinary_File
                 and then (for some Ending of Names.Vector'([".md", ".rst", ".adoc", ".txt"]) =>
                             Lower'Length > Ending'Length
                             and then Lower (Lower'Last - Ending'Length + 1 .. Lower'Last) = Ending)
                 and then not Read_Ones.Contains (Path)
                 --  A history of changes names what was asked long ago.
                 and then not (for some History of Names.Vector'(["changelog", "changes", "history", "news"])
                                 => Ada.Strings.Fixed.Index (Lower, History) = Lower'First)
                 and then (Ada.Strings.Fixed.Index (Lower, "requirement") > 0
                           or else Ada.Strings.Fixed.Index (Lower, "decision") > 0
                           or else Ada.Strings.Fixed.Index (Lower, "adr") = Lower'First
                           or else Says_Requirements (Full_Name (Next)))
                 and then Natural (Unread.Length) < 5
               then
                  Unread.Append (Path);
               end if;
            end;
         end loop;
         End_Search (Search);
      exception
         when others =>
            null;
      end Look;
      --  Read here and by a project of its own below: twice.
      Nested_Read : Names.Vector;
   begin
      for Path of Read_Ones loop
         declare
            Slash : Natural := Ada.Strings.Fixed.Index (Path, "/", Ada.Strings.Backward);
         begin
            while Slash > Path'First loop
               if Ada.Directories.Exists (Path (Path'First .. Slash - 1) & "/.model_runner") then
                  Nested_Read.Append (Path);
                  exit;
               end if;
               Slash := Ada.Strings.Fixed.Index (Path (Path'First .. Slash - 1), "/", Ada.Strings.Backward);
            end loop;
         end;
      end loop;
      if not Nested_Read.Is_Empty then
         Pres.Put_Note (Screen, "cli.next.bootstrap_nested", [Loc.Named ("detail", Joined_Names (Nested_Read))]);
      end if;
      Look (Ada.Directories.Current_Directory, "", 4);
      if not Unreadable.Is_Empty then
         Pres.Put_Note (Screen, "cli.next.bootstrap_unreadable",
                        [Loc.Named ("detail", Joined_Names (Unreadable))]);
      end if;
      if not Unread.Is_Empty then
         Pres.Put_Note (Screen, "cli.next.bootstrap_unread",
                        [Loc.Named ("detail", Joined_Names (Unread)),
                         Loc.Named ("value", Unread.First_Element)]);
      end if;
   end;

   --  Anything it made that waits on a person -- an entry of any
   --  register, or a task derived from what it accepted -- is
   --  pointed at as one: /accept goes through them all.
   if (for some Id of Report.Made =>
         (Ada.Strings.Fixed.Index (Id, "REQ-") = Id'First
          and then Nt.State_Of (Store, Nt.Requirement, Id) = Nt.First_State (Nt.Requirement))
         or else (Ada.Strings.Fixed.Index (Id, "SPEC-") = Id'First
                  and then Nt.State_Of (Store, Nt.Specification, Id) = Nt.First_State (Nt.Specification))
         or else (Ada.Strings.Fixed.Index (Id, "DEC-") = Id'First
                  and then Nt.State_Of (Store, Nt.Decision, Id) = Nt.First_State (Nt.Decision)))
     --  A task waits for it only where derived from what it made.
     or else (for some Task_Id of Tk.List (Store, "candidate") =>
                (for some Line of Task_Requirements (Store, Task_Id) => Report.Made.Contains (Line)))
   then
      Pres.Put_Note (Screen, "cli.next.bootstrap");
   elsif not Report.Made.Is_Empty
     and then not (for some Id of Report.Made => Ada.Strings.Fixed.Index (Id, "REQ-") = Id'First)
     and then Report.Existing = 0 and then Report.Revised.Is_Empty
   then
      Pres.Put_Note (Screen, "cli.next.bootstrap_no_requirement");
   end if;
end Bootstrap;
