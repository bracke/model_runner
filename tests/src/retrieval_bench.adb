with Ada.Calendar;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Environment_Variables;
with Ada.Text_IO;

with Model_Runner.Errors;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Context;
with Model_Runner.Framework.Derivations;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Retrieval;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Templates;

package body Retrieval_Bench is

   use Ada.Strings.Unbounded;
   use type Ada.Calendar.Time;

   package E renames Model_Runner.Errors;
   package S renames Model_Runner.Framework.Stores;
   package Tk renames Model_Runner.Framework.Tasks;
   package Tp renames Model_Runner.Framework.Templates;
   package Cf renames Model_Runner.Framework.Configurations;
   package Cx renames Model_Runner.Framework.Context;
   package Rp renames Model_Runner.Framework.Repository;
   package Rv renames Model_Runner.Framework.Retrieval;
   package Dirs renames Ada.Directories;

   LF : constant Character := ASCII.LF;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   --  A share as a fraction to three places: 0.833.
   function Share (Part, Whole : Natural) return String is
      Thousandths : constant Natural := (if Whole = 0 then 0 else (Part * 1000 + Whole / 2) / Whole);
      Digits_Of   : constant String := Image (1000 + Thousandths mod 1000);
   begin
      return Image (Thousandths / 1000) & "." & Digits_Of (Digits_Of'Last - 2 .. Digits_Of'Last);
   end Share;

   procedure Refuse (What : String; Status : E.Error_Info) is
   begin
      raise Program_Error with "retrieval-bench: " & What & ": " & E.Error_Code'Image (Status.Code);
   end Refuse;

   --  A line a model needs: the file it is in and the text of the line,
   --  found in the context however the file is shown.
   type Anchor is record
      Path : Unbounded_String;
      Line : Unbounded_String;
   end record;

   type Anchor_List is array (Positive range <>) of Anchor;

   function A (Path, Line : String) return Anchor
   is (To_Unbounded_String (Path), To_Unbounded_String (Line));

   type Rooms is array (Positive range <>) of Positive;

   --  What a search should find for a query, named before it is run: a
   --  symbol's full name, or a file's path -- found where a hit is in it.
   type Relevant_List is array (Positive range <>) of Unbounded_String;

   function R (Name : String) return Unbounded_String renames To_Unbounded_String;

   Src : constant String := "src/model_runner-framework-";

   ---------
   -- Run --
   ---------

   procedure Run is
      Store  : S.Store;
      Change : S.Transaction;
      Status : E.Error_Info;

      Total_Found, Total_Wanted, Total_Source, Total_Cost : Natural := 0;

      --  The arm measured -- "excerpts", or "whole": the retrieval as it
      --  was before excerpts, the same tasks in the same rooms -- and the
      --  tree it is made in.
      Arm  : Unbounded_String;
      Root : Unbounded_String;

      --  Build one case's context in a room and say what it held.
      procedure Measure (Named, Title, Component : String; Anchors : Anchor_List) is
         Id : Unbounded_String;
      begin
         declare
            Given : Tk.Field_Map;
         begin
            Given.Include ("title", Title);
            Given.Include ("kind", "implementation");
            Given.Include ("component", Component);
            Tk.Create (Store, Change, Given, "user", "", Id, Status);
            S.Commit (Store, Change, Status);
            if E.Is_Error (Status) then
               Refuse ("the task was not made", Status);
            end if;
         end;
         for Room of Rooms'[4_096, 8_192, 32_768] loop
            declare
               Model : constant Cx.Model_Profile :=
                 (Id => To_Unbounded_String ("bench"), Context_Limit => Room, Output_Reserve => 1_024,
                  others => <>);
               Made   : Cx.Built;
               Began  : Ada.Calendar.Time;
               Took   : Duration;
               Found  : Natural := 0;
               Source : Natural := 0;
               Pieces : Natural := 0;
            begin
               Model_Runner.Framework.Derivations.Forget;
               Began := Ada.Calendar.Clock;
               Cx.Build (Store, To_String (Id), Model, Made, Status);
               Took := Ada.Calendar.Clock - Began;
               if E.Is_Error (Status) then
                  Refuse ("the context for " & Named & " was not built", Status);
               end if;
               declare
                  Said : constant String := Cx.Rendered (Made);
                  Kept : Ada.Text_IO.File_Type;
               begin
                  --  What the model would be given, beside the project, to
                  --  read where a figure surprises.
                  Ada.Text_IO.Create
                    (Kept, Ada.Text_IO.Out_File, To_String (Root) & "/" & Named & "-" & Image (Room) & ".txt");
                  Ada.Text_IO.Put (Kept, Said);
                  Ada.Text_IO.Close (Kept);
                  for Wanted of Anchors loop
                     if Ada.Strings.Fixed.Index (Said, To_String (Wanted.Line)) > 0 then
                        Found := Found + 1;
                     end if;
                  end loop;
               end;
               for Index in 1 .. Cx.Included_Count (Made) loop
                  declare
                     Shown : constant Cx.Item := Cx.Included_At (Made, Index);
                     Id_Of : constant String := To_String (Shown.Id);
                  begin
                     if Id_Of'Length > 5
                       and then (Id_Of (Id_Of'First .. Id_Of'First + 4) in "file:" | "code:")
                     then
                        Source := Source + Cx.Estimate (To_String (Shown.Text));
                        Pieces := Pieces + 1;
                     end if;
                  end;
               end loop;
               Ada.Text_IO.Put_Line
                 (To_String (Arm) & " " & Named & " room " & Image (Room) & ": recall " & Image (Found) & "/"
                  & Image (Anchors'Length) & ", source " & Image (Source) & " tokens in " & Image (Pieces)
                  & " pieces, context " & Image (Cx.Cost (Made)) & " of " & Image (Cx.Budget (Made)) & ", "
                  & Image (Natural (Took * 1000.0)) & " ms");
               Total_Found := Total_Found + Found;
               Total_Wanted := Total_Wanted + Anchors'Length;
               Total_Source := Total_Source + Source;
               Total_Cost := Total_Cost + Cx.Cost (Made);
            end;
         end loop;
      end Measure;

      procedure Copy (From, Into : String) is
         Search : Dirs.Search_Type;
         Found  : Dirs.Directory_Entry_Type;
      begin
         Dirs.Create_Path (Into);
         Dirs.Start_Search (Search, From, "*.ad?");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Found);
            Dirs.Copy_File (Dirs.Full_Name (Found), Into & "/" & Dirs.Simple_Name (Found));
         end loop;
         Dirs.End_Search (Search);
      end Copy;

      Lookup_Title  : constant String := "Find_Symbols folds case only for Ada files; fold it for Python files too";
      Callers_Title : constant String := "Units_Of_File should also give a file's subprogram units";
      Estimate_Title : constant String := "Make Estimate count a token per four bytes of text";
      Impact_Title  : constant String := "Impact_Of should not follow uncertain relations";
      Tests_Title   : constant String := "Find_Symbols misses a Rust symbol asked for as crate::fnv::fnv1a";

      --  The project made in one arm, and its tasks' contexts built and
      --  measured: left open for the searches after.
      procedure Contexts (Whole : Boolean) is
      begin
         Arm := To_Unbounded_String (if Whole then "whole" else "excerpts");
         Root := To_Unbounded_String (Dirs.Full_Name ("obj/retrieval-bench" & (if Whole then "-whole" else "")));
         Total_Found := 0;
         Total_Wanted := 0;
         Total_Source := 0;
         Total_Cost := 0;
         if Dirs.Exists (To_String (Root)) then
            Dirs.Delete_Tree (To_String (Root));
         end if;
         Dirs.Create_Path (To_String (Root));
         declare
            Registry : Tp.Registry;
            Template : Tp.Template;
            Composed : Tp.Composition;
            Given    : Cf.Value_Maps.Map;
            Planned  : Cf.Plan;
            Done     : Cf.Outcome;
         begin
            Tp.Parse ("template = work" & LF & "name = W" & LF & "description = D" & LF & "version = 1" & LF
                      & "task_kind implementation = component, requirements?, notes?" & LF
                      & "scalar task.profile.implementation = tests" & LF
                      & (if Whole then "scalar context.retrieval = whole" & LF else "")
                      & "profile tests = run the tests" & LF, "memory", Template, Status);
            Tp.Add (Registry, Template);
            Tp.Compose (Registry, "work", Composed, Status);
            Cf.Prepare (Composed, To_String (Root), Given, Planned, Status);
            Cf.Initialize (Store, To_String (Root), Planned, Done, Status);
            if E.Is_Error (Status) then
               Refuse ("the project was not made", Status);
            end if;
         end;
         Copy ("fixtures/retrieval-bench/src", To_String (Root) & "/src");
         Copy ("fixtures/retrieval-bench/tests", To_String (Root) & "/tests");
         --  Old enough for what is read of them to be remembered by stamp.
         delay 2.1;

         Measure
           ("lookup", Lookup_Title, "repository",
            [A (Src & "repository.ads",
                "function Find_Symbols (From : Graph; Name : String) return Name_Lists.Vector;"),
             A (Src & "repository.adb",
                "Folds  : constant Boolean := Language_Of (To_String (Item.Path)) = ""Ada"";")]);
         Measure
           ("callers", Callers_Title, "code_queries",
            [A (Src & "code_queries.ads", "--  The units a file declares, as the graph knows them"),
             A (Src & "code_queries.adb", "return Units_Of_File (Graph, Spec);"),
             A (Src & "context.adb", "for Unit of Code_Queries.Units_Of_File (Graph, Named) loop"),
             A (Src & "code_queries.adb", "for Unit of Units_Of_File (Graph, Path) loop")]);
         Measure
           ("implementation", Estimate_Title, "context",
            [A (Src & "context.ads", "function Estimate (Text : String) return Natural;"),
             A (Src & "context.adb", "is ((Text'Length + 2) / 3);")]);
         Measure
           ("impact", Impact_Title, "traceability",
            [A (Src & "traceability.adb",
                "function Impact_Of (From : Graph; Changed : Name_Lists.Vector) return Impact is"),
             A (Src & "code_queries.adb",
                "Reach : constant Tc.Impact := Tc.Impact_Of (Tc.Build (Store, Graph), Node);")]);
         Measure
           ("tests", Tests_Title, "repository",
            [A (Src & "repository.adb", "--  Rust's paths: crate::fnv::fnv1a is fnv1a, and fnv::fnv1a."),
             A ("tests/repository_tests.adb", "procedure Symbols_Are_Found_By_Name (Found : Rp.Graph) is")]);
         Ada.Text_IO.Put_Line
           (To_String (Arm) & " all: recall " & Image (Total_Found) & "/" & Image (Total_Wanted) & ", source "
            & Image (Total_Source) & " tokens, contexts " & Image (Total_Cost) & " tokens, "
            & Image (Total_Source / Natural'Max (1, Total_Found)) & " source tokens a line found");
      end Contexts;

      Judged_Named, Within_5, Within_10, Reciprocals : Natural := 0;
      Queries : Natural := 0;

      --  One query searched and held against what it should find: where
      --  each named thing first is among the hits, and the first of them.
      procedure Judge (Query : String; Relevant : Relevant_List) is
         Graph : constant Rp.Graph := Rp.Scan (To_String (Root), Rp.Default_Roots);
         Hits  : constant Rv.Hit_Lists.Vector :=
           Rv.Search (Store, Graph, To_String (Root), Query, Most => 10, Records => False);
         First : Natural := 0;
         Ranks : Unbounded_String;
      begin
         for Wanted of Relevant loop
            declare
               Rank : Natural := 0;
            begin
               for Index in 1 .. Natural (Hits.Length) loop
                  if Hits (Index).Name = Wanted or else Hits (Index).Path = Wanted then
                     Rank := Index;
                     exit;
                  end if;
               end loop;
               Append (Ranks, " " & (if Rank = 0 then "-" else Image (Rank)));
               if Rank in 1 .. 5 then
                  Within_5 := Within_5 + 1;
               end if;
               if Rank in 1 .. 10 then
                  Within_10 := Within_10 + 1;
               end if;
               if Rank > 0 and then (First = 0 or else Rank < First) then
                  First := Rank;
               end if;
            end;
         end loop;
         Judged_Named := Judged_Named + Relevant'Length;
         Queries := Queries + 1;
         --  In thousandths, summed: the mean taken at the end.
         Reciprocals := Reciprocals + (if First = 0 then 0 else 1000 / First);
         if Ada.Environment_Variables.Exists ("BENCH_TOP") then
            for Index in 1 .. Natural'Min (6, Natural (Hits.Length)) loop
               Ada.Text_IO.Put_Line ("   " & Image (Hits (Index).Score) & " " & To_String (Hits (Index).Name) & " | "
                                     & To_String (Hits (Index).Why));
            end loop;
         end if;
         Ada.Text_IO.Put_Line
           ("search " & Image (Queries) & ": ranks" & To_String (Ranks) & "; first relevant "
            & (if First = 0 then "none" else Image (First)) & "; best " & To_String (Hits.First_Element.Name));
      end Judge;
   begin
      Contexts (Whole => True);
      S.Close (Store);
      Contexts (Whole => False);

      --  Search, judged on the excerpts arm's tree: the tasks' titles as
      --  queries, with what a developer would open for each named first.
      Rv.Forget;
      Judge (Lookup_Title,
             [R ("Model_Runner.Framework.Repository.Find_Symbols"), R (Src & "repository.adb")]);
      Judge (Callers_Title,
             [R ("Model_Runner.Framework.Code_Queries.Units_Of_File"), R (Src & "code_queries.adb"),
              R (Src & "context.adb")]);
      Judge (Estimate_Title, [R ("Model_Runner.Framework.Context.Estimate"), R (Src & "context.adb")]);
      Judge (Impact_Title,
             [R ("Model_Runner.Framework.Traceability.Impact_Of"), R (Src & "traceability.adb"),
              R (Src & "code_queries.adb")]);
      Judge (Tests_Title,
             [R ("Model_Runner.Framework.Repository.Find_Symbols"), R (Src & "repository.adb"),
              R ("tests/repository_tests.adb")]);
      Judge ("crate::fnv::fnv1a", [R (Src & "repository.adb"), R ("tests/repository_tests.adb")]);
      Judge ("Impact_Of", [R ("Model_Runner.Framework.Traceability.Impact_Of")]);
      Judge ("uncertain relations", [R (Src & "traceability.adb")]);
      --  Tasks as an agent is given them, judged from the sources before
      --  they were searched.
      Judge ("Graph_Fingerprint should also change when a file is only renamed",
             [R ("Model_Runner.Framework.Repository.Graph_Fingerprint"), R (Src & "repository.adb")]);
      Judge ("References_To misses calls made through a package renaming",
             [R ("Model_Runner.Framework.Repository.References_To"), R (Src & "repository.adb")]);
      Judge ("Users_Of_File lists a dependent twice",
             [R ("Model_Runner.Framework.Code_Queries.Users_Of_File"), R (Src & "code_queries.adb")]);
      Judge ("Language_Of does not know .hpp headers",
             [R ("Model_Runner.Framework.Repository.Language_Of"), R (Src & "repository.adb")]);
      Judge ("Refresh reads a file again though its stamp is unchanged",
             [R ("Model_Runner.Framework.Repository.Refresh"), R (Src & "repository.adb")]);
      Judge ("the context Budget leaves no room for the model's reply",
             [R ("Model_Runner.Framework.Context.Budget"), R (Src & "context.adb")]);
      --  Tasks said without the name of what they are about, as a
      --  developer new to the code says them: judged from the specs'
      --  comments before they were searched, and tallied apart as well.
      declare
         Named_5 : constant Natural := Within_5;
         Named_10 : constant Natural := Within_10;
         Named_Reciprocals : constant Natural := Reciprocals;
         Named_Judged : constant Natural := Judged_Named;
         Named_Queries : constant Natural := Queries;
         Rp_Name : constant String := "Model_Runner.Framework.Repository.";
         Tc_Name : constant String := "Model_Runner.Framework.Traceability.";
         Cx_Name : constant String := "Model_Runner.Framework.Context.";
      begin
         Judge ("a file that says a tool made it and it is not to be edited",
                [R (Rp_Name & "Says_Generated"), R (Src & "repository.adb")]);
         Judge ("what a file is for, from its place in the project",
                [R (Rp_Name & "Role_Of"), R (Src & "repository.adb")]);
         Judge ("a typed path that climbs out of the project is to be refused",
                [R (Rp_Name & "Relative_Path"), R (Src & "repository.adb")]);
         Judge ("whether a path is under a folder the roots name, or matches a pattern",
                [R (Rp_Name & "Under_Roots"), R (Src & "repository.adb")]);
         Judge ("a binary fixture replaced is a change a snapshot must see",
                [R (Rp_Name & "Binary_Files"), R (Src & "repository.adb")]);
         Judge ("the paths the walk could not read",
                [R (Rp_Name & "Unread_Paths"), R (Src & "repository.adb")]);
         Judge ("the units that depend on a unit",
                [R (Rp_Name & "Dependents_Of"), R (Src & "repository.adb")]);
         Judge ("narrow escalation tests only what is certainly affected",
                [R (Tc_Name & "Select_Tests"), R (Src & "traceability.adb")]);
         Judge ("the edges that touch a node",
                [R (Tc_Name & "Touching"), R (Src & "traceability.adb")]);
         Judge ("the model's room and reserve as the configuration plans them",
                [R (Cx_Name & "Within_Configured"), R (Cx_Name & "Profile"), R (Src & "context.adb")]);
         Judge ("why an item was left out of the context",
                [R (Cx_Name & "Excluded_Why"), R (Src & "context.adb")]);
         Judge ("whether every index was built from the repository as it is now",
                [R ("Model_Runner.Framework.Indexes.Current"), R (Src & "indexes.adb")]);
         Judge ("which adapter reads a language",
                [R (Rp_Name & "Languages.Adapter_For"), R (Src & "repository-languages.adb")]);
         Judge ("the fingerprint of the graph kept in the project state",
                [R (Rp_Name & "Kept_Fingerprint"), R (Src & "repository.adb")]);
         declare
            Dev_5 : constant Natural := Within_5;
            Dev_10 : constant Natural := Within_10;
            Dev_Reciprocals : constant Natural := Reciprocals;
            Dev_Judged : constant Natural := Judged_Named;
            Dev_Queries : constant Natural := Queries;
            Ix_Name : constant String := "Model_Runner.Framework.Indexes.";
         begin
            --  Held out: written with the ones above, before the weights
            --  for descriptions were set, and not looked at while setting
            --  them; said in other words than the comments say.
            Judge ("the text given to the model",
                   [R (Cx_Name & "Rendered"), R (Src & "context.adb")]);
            Judge ("observations a context did not offer and why",
                   [R (Cx_Name & "Knowledge_Left"), R (Src & "context.adb")]);
            Judge ("was the context built with the graph or the textual fallback",
                   [R (Cx_Name & "Semantic"), R (Src & "context.adb")]);
            Judge ("keeping the same context twice stages nothing",
                   [R (Cx_Name & "Keep"), R (Src & "context.adb")]);
            Judge ("build every index from the state and the graph",
                   [R (Ix_Name & "Build"), R (Src & "indexes.adb")]);
            Judge ("choose the tests a change calls for",
                   [R (Tc_Name & "Select_For"), R (Src & "traceability.adb")]);
            Judge ("where a component's files are declared in the configuration",
                   [R (Rp_Name & "Component_Roots"), R (Src & "repository.adb")]);
            Judge ("whether a file belongs to a component by its roots",
                   [R (Rp_Name & "In_Component"), R (Src & "repository.adb")]);
            Judge ("how many things the walk could not read",
                   [R (Rp_Name & "Unread_Count"), R (Src & "repository.adb")]);
            Judge ("a question to the graph asked as a tool call",
                   [R ("Model_Runner.Framework.Code_Queries.Answer"), R (Src & "code_queries.adb")]);
            Ada.Text_IO.Put_Line
              ("search held out: recall@5 " & Share (Within_5 - Dev_5, Judged_Named - Dev_Judged)
               & ", recall@10 " & Share (Within_10 - Dev_10, Judged_Named - Dev_Judged) & ", MRR "
               & Share (Reciprocals - Dev_Reciprocals, (Queries - Dev_Queries) * 1000) & " over "
               & Image (Queries - Dev_Queries) & " queries");
            Within_5 := Dev_5;
            Within_10 := Dev_10;
            Reciprocals := Dev_Reciprocals;
            Judged_Named := Dev_Judged;
            Queries := Dev_Queries;
         end;
         Ada.Text_IO.Put_Line
           ("search named: recall@5 " & Share (Named_5, Named_Judged) & ", recall@10 "
            & Share (Named_10, Named_Judged) & ", MRR " & Share (Named_Reciprocals, Named_Queries * 1000)
            & " over " & Image (Named_Queries) & " queries");
         Ada.Text_IO.Put_Line
           ("search descriptions: recall@5 " & Share (Within_5 - Named_5, Judged_Named - Named_Judged)
            & ", recall@10 " & Share (Within_10 - Named_10, Judged_Named - Named_Judged) & ", MRR "
            & Share (Reciprocals - Named_Reciprocals, (Queries - Named_Queries) * 1000) & " over "
            & Image (Queries - Named_Queries) & " queries");
      end;
      Ada.Text_IO.Put_Line
        ("search all: recall@5 " & Share (Within_5, Judged_Named) & ", recall@10 "
         & Share (Within_10, Judged_Named) & ", MRR " & Share (Reciprocals, Queries * 1000) & " over "
         & Image (Queries) & " queries, " & Image (Judged_Named) & " judged");

      --  What a search costs, warm: each judged query five times over, on
      --  the fixture's tree and on this repository's own, its time and the
      --  files it read -- the index's reading and the lines read again for
      --  the line shown. The middle and the 95th of the times are said.
      declare
         type Times is array (Positive range <>) of Duration;
         procedure Sort_Times (Item : in out Times) is
            Held : Duration;
         begin
            for I in Item'First + 1 .. Item'Last loop
               Held := Item (I);
               declare
                  J : Natural := I - 1;
               begin
                  while J >= Item'First and then Item (J) > Held loop
                     Item (J + 1) := Item (J);
                     J := J - 1;
                  end loop;
                  Item (J + 1) := Held;
               end;
            end loop;
         end Sort_Times;

         Queries : constant array (1 .. 8) of Unbounded_String :=
           [R (Lookup_Title), R (Callers_Title), R (Estimate_Title), R (Impact_Title), R (Tests_Title),
            R ("crate::fnv::fnv1a"), R ("Impact_Of"), R ("uncertain relations")];

         procedure Latency (Label, Tree : String) is
            Graph  : constant Rp.Graph := Rp.Scan (Tree, Rp.Default_Roots);
            Took   : Times (1 .. Queries'Length * 5);
            Taken  : Natural := 0;
            Read_Before : Natural;
            Hits   : Rv.Hit_Lists.Vector;
         begin
            --  Warm: the index brought up once before any is timed.
            Hits := Rv.Search (Store, Graph, Tree, To_String (Queries (1)), Most => 10, Records => False);
            Read_Before := Rv.Files_Read;
            for Round in 1 .. 5 loop
               for Query of Queries loop
                  declare
                     Began : constant Ada.Calendar.Time := Ada.Calendar.Clock;
                  begin
                     Hits := Rv.Search (Store, Graph, Tree, To_String (Query), Most => 10, Records => False);
                     Taken := Taken + 1;
                     Took (Taken) := Ada.Calendar.Clock - Began;
                  end;
               end loop;
            end loop;
            Sort_Times (Took);
            Ada.Text_IO.Put_Line
              ("latency " & Label & ": p50 " & Image (Natural (Took ((Took'Length + 1) / 2) * 1000.0)) & " ms, p95 "
               & Image (Natural (Took ((Took'Length * 95 + 99) / 100) * 1000.0)) & " ms over "
               & Image (Took'Length) & " warm searches; "
               & Share (Rv.Files_Read - Read_Before, Took'Length) & " files read a search, the last giving "
               & Image (Natural (Hits.Length)) & " hits");
         end Latency;

         --  The same searches from three tasks at once -- two on this
         --  repository, one on the fixture -- each search timed, and the
         --  whole against the three run one after another: what waiting
         --  on the index's lock costs agents searching side by side.
         procedure Together is
            Trees  : constant array (1 .. 3) of Unbounded_String :=
              [R (Dirs.Full_Name ("..")), R (Dirs.Full_Name ("..")), Root];
            Graphs : array (Trees'Range) of Rp.Graph;
            Each   : constant Positive := Queries'Length * 5;
            Took   : Times (1 .. Each * Trees'Length);
            Failed : Boolean := False with Atomic;

            procedure Run_Searches (Which : Positive) is
               Hits : Rv.Hit_Lists.Vector;
               At_Took : Natural := (Which - 1) * Each;
            begin
               for Round in 1 .. 5 loop
                  for Query of Queries loop
                     declare
                        Began : constant Ada.Calendar.Time := Ada.Calendar.Clock;
                     begin
                        Hits := Rv.Search (Store, Graphs (Which), To_String (Trees (Which)), To_String (Query),
                                           Most => 10, Records => False);
                        At_Took := At_Took + 1;
                        Took (At_Took) := Ada.Calendar.Clock - Began;
                     end;
                  end loop;
               end loop;
               if Hits.Is_Empty then
                  Failed := True;
               end if;
            end Run_Searches;

            Began  : Ada.Calendar.Time;
            Alone  : Duration;
            At_Once : Duration;
         begin
            for Which in Trees'Range loop
               Graphs (Which) := Rp.Scan (To_String (Trees (Which)), Rp.Default_Roots);
            end loop;
            Began := Ada.Calendar.Clock;
            for Which in Trees'Range loop
               Run_Searches (Which);
            end loop;
            Alone := Ada.Calendar.Clock - Began;
            Began := Ada.Calendar.Clock;
            declare
               task type Searcher (Which : Positive);
               task body Searcher is
               begin
                  Run_Searches (Which);
               exception
                  when others =>
                     Failed := True;
               end Searcher;
               First  : Searcher (1);
               Second : Searcher (2);
               Third  : Searcher (3);
            begin
               null;
            end;
            At_Once := Ada.Calendar.Clock - Began;
            Sort_Times (Took);
            Ada.Text_IO.Put_Line
              ("latency together: p50 " & Image (Natural (Took ((Took'Length + 1) / 2) * 1000.0)) & " ms, p95 "
               & Image (Natural (Took ((Took'Length * 95 + 99) / 100) * 1000.0)) & " ms over "
               & Image (Took'Length) & " searches from 3 tasks; all "
               & Image (Natural (At_Once * 1000.0)) & " ms at once against "
               & Image (Natural (Alone * 1000.0)) & " ms one after another"
               & (if Failed then "; A SEARCH FAILED" else ""));
         end Together;
      begin
         Latency ("fixture", To_String (Root));
         Latency ("repository", Dirs.Full_Name (".."));
         Together;
      end;

      --  Held out, and not written for the bench: this repository's own
      --  commit subjects, the area label cut, each judged by the source
      --  files its commit changed (fixtures/retrieval-commits.tsv, made
      --  once from git log). A hit is relevant where its file is one of
      --  them; the rank of the first, and how many of the files the first
      --  ten name, are counted.
      --  The older sixty (retrieval-commits-dev.tsv) are what ranking is
      --  tuned on; the newer are looked at only once a change is made.
      declare
         Tree   : constant String := Dirs.Full_Name ("..");
         Graph  : constant Rp.Graph := Rp.Scan (Tree, Rp.Default_Roots);

         --  The sets themselves hold every query word for word: not searched.
         function Not_The_Sets (Path : String) return Boolean
         is (Ada.Strings.Fixed.Index (Path, "fixtures/retrieval-commits") = 0);

         procedure Judge_Commits (Named_File, Label : String) is
            Source : Ada.Text_IO.File_Type;
            Asked, Judged, Found_10, Any_10 : Natural := 0;
            Reciprocals : Natural := 0;
         begin
            Ada.Text_IO.Open (Source, Ada.Text_IO.In_File, Named_File);
            while not Ada.Text_IO.End_Of_File (Source) loop
               declare
                  Line   : constant String := Ada.Text_IO.Get_Line (Source);
                  First  : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
                  Second : constant Natural :=
                    (if First = 0 then 0 else Ada.Strings.Fixed.Index (Line (First + 1 .. Line'Last), [1 => ASCII.HT]));
               begin
                  if Line'Length > 0 and then Line (Line'First) /= '#' and then Second > 0 then
                     declare
                        Query  : constant String := Line (First + 1 .. Second - 1);
                        Files  : constant String := " " & Line (Second + 1 .. Line'Last) & " ";
                        Hits   : constant Rv.Hit_Lists.Vector :=
                          Rv.Search (Store, Graph, Tree, Query, Most => 10,
                                     May_Read => Not_The_Sets'Unrestricted_Access, Records => False);
                        Wanted : Natural := 0;
                        Named  : Unbounded_String := To_Unbounded_String (" ");
                        Rank   : Natural := 0;
                     begin
                        for C of Files loop
                           if C = ' ' then
                              Wanted := Wanted + 1;
                           end if;
                        end loop;
                        Wanted := Wanted - 1;
                        for At_Hit in 1 .. Natural (Hits.Length) loop
                           declare
                              Path : constant String := To_String (Hits (At_Hit).Path);
                           begin
                              if Path /= "" and then Ada.Strings.Fixed.Index (Files, " " & Path & " ") > 0 then
                                 if Rank = 0 then
                                    Rank := At_Hit;
                                 end if;
                                 if Ada.Strings.Fixed.Index (To_String (Named), " " & Path & " ") = 0 then
                                    Append (Named, Path & " ");
                                 end if;
                              end if;
                           end;
                        end loop;
                        Asked := Asked + 1;
                        Judged := Judged + Wanted;
                        for C of To_String (Named) loop
                           if C = ' ' then
                              Found_10 := Found_10 + 1;
                           end if;
                        end loop;
                        Found_10 := Found_10 - 1;
                        if Rank > 0 then
                           Any_10 := Any_10 + 1;
                           Reciprocals := Reciprocals + 1000 / Rank;
                        end if;
                        if Ada.Environment_Variables.Exists ("BENCH_TOP") then
                           Ada.Text_IO.Put_Line
                             ("commit " & Line (Line'First .. First - 1) & ": first relevant"
                              & (if Rank = 0 then " -" else Natural'Image (Rank)) & "; " & Query
                              & (if Hits.Is_Empty then "" else " | best " & To_String (Hits.First_Element.Path)));
                        end if;
                        --  BENCH_TOP=all: the ten, each with its kind, a * on
                        --  one judged relevant.
                        if Ada.Environment_Variables.Exists ("BENCH_TOP")
                          and then Ada.Environment_Variables.Value ("BENCH_TOP") = "all"
                        then
                           for One of Hits loop
                              Ada.Text_IO.Put_Line
                                ("   " & (if Ada.Strings.Fixed.Index (Files, " " & To_String (One.Path) & " ") > 0
                                          then "* " else "  ")
                                 & Rv.Hit_Kind'Image (One.Kind) & Natural'Image (One.Score) & " "
                                 & To_String (One.Name));
                           end loop;
                        end if;
                     end;
                  end if;
               end;
            end loop;
            Ada.Text_IO.Close (Source);
            Ada.Text_IO.Put_Line
              ("search commits (" & Label & "): a relevant file in the first 10 for " & Share (Any_10, Asked)
               & ", recall@10 " & Share (Found_10, Judged) & ", MRR " & Share (Reciprocals, Asked * 1000)
               & " over " & Image (Asked) & " queries, " & Image (Judged) & " files judged");
         end Judge_Commits;
      begin
         Judge_Commits ("fixtures/retrieval-commits-dev.tsv", "dev");
         Judge_Commits ("fixtures/retrieval-commits.tsv", "held out");
      end;

      --  The index of the words over a tree of some size: this repository's
      --  own, scanned, then searched cold, warm, and with a file changed.
      declare
         Tree   : constant String := Dirs.Full_Name ("..");
         Began  : Ada.Calendar.Time := Ada.Calendar.Clock;
         Graph  : constant Rp.Graph := Rp.Scan (Tree, Rp.Default_Roots);
         Scanned : constant Duration := Ada.Calendar.Clock - Began;
         Hits   : Rv.Hit_Lists.Vector;

         function Millis (Took : Duration) return String
         is (Image (Natural (Took * 1000.0)) & " ms");
      begin
         Rv.Forget;
         Began := Ada.Calendar.Clock;
         Hits := Rv.Search (Store, Graph, Tree, "context budget settle", Most => 15, Records => False);
         Ada.Text_IO.Put_Line
           ("index: " & Image (Rp.File_Count (Graph)) & " files scanned in " & Millis (Scanned) & "; first search "
            & Millis (Ada.Calendar.Clock - Began) & " reading " & Image (Rv.Indexed_Reads) & " files");
         Began := Ada.Calendar.Clock;
         Hits := Rv.Search (Store, Graph, Tree, "context budget settle", Most => 15, Records => False);
         Ada.Text_IO.Put_Line ("index: warm search " & Millis (Ada.Calendar.Clock - Began) & ", best "
                               & To_String (Hits.First_Element.Name));
         --  Of that, what checking the graph against the tree costs: a walk
         --  of it, every file's stamp.
         Began := Ada.Calendar.Clock;
         Ada.Text_IO.Put_Line ("index: graph checked current " & Boolean'Image (Rp.Is_Current (Tree, Graph)) & " in "
                               & Millis (Ada.Calendar.Clock - Began));
      end;
      S.Close (Store);
   end Run;

end Retrieval_Bench;
