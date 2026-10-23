with Ada.Calendar;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
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
      Ada.Text_IO.Put_Line
        ("search all: recall@5 " & Share (Within_5, Judged_Named) & ", recall@10 "
         & Share (Within_10, Judged_Named) & ", MRR " & Share (Reciprocals, Queries * 1000) & " over "
         & Image (Queries) & " queries, " & Image (Judged_Named) & " judged");

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
