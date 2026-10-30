with Project_Tools.Tree_Checks;
with Ada.Strings.Unbounded;
with AUnit.Test_Cases;
with AUnit.Assertions; use AUnit.Assertions;

with Ada.Directories;
with Ada.Text_IO;
with Ada.Strings.Fixed;

with Project_Tools.Files;

with Checks;
with Spec_Conformance;
with GNAT.SHA1;
with Conformance;
with Tiny_Model;
with Suite_Filter;

package body Tests.Gate_Cases is

   use type Checks.Build_Evidence;
   use type Tiny_Model.Weight_Format;

   package Dirs renames Ada.Directories;
   package Files renames Project_Tools.Files;

   --  Where the fixtures of this case are made, under the tests' own
   --  object directory, fresh for each routine that asks.
   Scratch : constant String := "obj/gate-fixtures";

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("the release gate");
   end Name;

   --  A directory made anew, whatever was there.
   procedure Fresh (Path : String) is
   begin
      if Dirs.Exists (Path) then
         Dirs.Delete_Tree (Path);
      end if;
      Dirs.Create_Path (Path);
   end Fresh;

   --  A text file as its lines read, with any carriage return the checkout
   --  put before a line feed taken off: what the catalog is, whichever way
   --  the host ended its lines, before this case ends them each way itself.
   function Text_Of (Path : String) return String is
      Whole : constant String := Files.Read_Raw_File (Path);
      Room  : String (1 .. Whole'Length);
      Used  : Natural := 0;
   begin
      for Letter of Whole loop
         if Letter /= Character'Val (13) then
            Used := Used + 1;
            Room (Used) := Letter;
         end if;
      end loop;

      return Room (1 .. Used);
   end Text_Of;

   --  A file holding Content, its directory made first.
   procedure Put (Path, Content : String) is
   begin
      Dirs.Create_Path (Dirs.Containing_Directory (Path));
      Files.Write_Raw_File (Path, Content);
   end Put;

   -----------------------------------------
   -- Short_Sweep_Crosses_Binary32_Alone --
   -----------------------------------------

   --  The short sweep's contract is binary32 weights alone, on the
   --  processor's arm and the device's, which both ask this one question;
   --  the full sweep crosses every format.
   procedure Short_Sweep_Crosses_Binary32_Alone
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      for Format in Tiny_Model.Weight_Format loop
         Assert (Conformance.Crosses (Format, Short_Sweep => False),
                 "the full sweep leaves out "
                 & Tiny_Model.Weight_Format'Image (Format));
         Assert (Conformance.Crosses (Format, Short_Sweep => True)
                   = (Format = Tiny_Model.F32),
                 "the short sweep's answer for "
                 & Tiny_Model.Weight_Format'Image (Format)
                 & " is not binary32's alone");
      end loop;
   end Short_Sweep_Crosses_Binary32_Alone;

   ----------------------------------------------
   -- Accounting_Holds_To_What_Was_Asked_For --
   ----------------------------------------------

   --  A sweep is accounted for when every comparison it asked for was made
   --  or counted as one with nothing to compare; one short of that is a
   --  comparison silently lost, and the gate does not pass it.
   procedure Accounting_Holds_To_What_Was_Asked_For
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Whole : Conformance.Report;
   begin
      Whole.Sequences := 7_087;
      Whole.Not_Applicable := 403;
      Whole.Requested := 7_490;
      Whole.Wanted := Whole.Requested;
      Assert (Conformance.Accounted (Whole),
              "every comparison asked for was accounted for and the sweep "
              & "says otherwise");

      Whole.Ran := Conformance.Accounted (Whole);
      Assert (Conformance.Is_Clean (Whole), "an accounted sweep is not clean");

      Whole.Sequences := Whole.Sequences - 1;
      Assert (not Conformance.Accounted (Whole),
              "a comparison lost without a word was accounted for");

      Whole.Ran := Conformance.Accounted (Whole);
      Assert (not Conformance.Is_Clean (Whole),
              "a sweep that lost a comparison passed the gate");
   end Accounting_Holds_To_What_Was_Asked_For;

   ----------------------------------------------------
   -- A_Prepared_Crate_That_Compiled_Nothing_Is_Said --
   ----------------------------------------------------

   --  A crate whose object directory was made and holds nothing compiled --
   --  what a build prepares for a crate pinned for a tool that did not run
   --  -- was not built; the directory alone is not evidence.
   procedure A_Prepared_Crate_That_Compiled_Nothing_Is_Said
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Crate : constant String := Scratch & "/prepared";
   begin
      Fresh (Crate);
      Put (Crate & "/src/prepared.adb", "package body Prepared is end;");
      Dirs.Create_Path (Crate & "/obj/development");
      Dirs.Create_Path (Crate & "/obj/release");
      Put (Crate & "/obj/development/prepared.stderr", "");

      Assert (not Checks.Compiled_Anything (Crate, "prepared"),
              "an object directory with nothing compiled in it read as a "
              & "build");
      Assert (Checks.Evidence_Of (Checks.Compiled_Anything (Crate), 0)
                = Checks.Not_Built,
              "a prepared crate that compiled nothing was not said to be "
              & "unbuilt");
   end A_Prepared_Crate_That_Compiled_Nothing_Is_Said;

   -------------------------------------------
   -- A_Crate_Compiled_Out_Of_Reach_Fails --
   -------------------------------------------

   --  A crate that compiled units none of which match a source of its tree
   --  is a check reading the wrong place, and fails; one whose units match
   --  is judged. A project naming its object directory after itself is
   --  evidence too.
   procedure A_Crate_Compiled_Out_Of_Reach_Fails
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Crate : constant String := Scratch & "/unmatched";
      Named : constant String := Scratch & "/named";
   begin
      Fresh (Crate);
      Put (Crate & "/src/unmatched.adb", "package body Unmatched is end;");
      Put (Crate & "/obj/release/elsewhere.ali", "V ""GNAT Lib v15""");

      Assert (Checks.Compiled_Anything (Crate),
              "a crate with a compiled unit read as unbuilt");
      Assert (Checks.Evidence_Of (Checks.Compiled_Anything (Crate), 0)
                = Checks.Unmatched,
              "a crate whose compiled units match none of its sources was "
              & "not failed");
      Assert (Checks.Evidence_Of (Checks.Compiled_Anything (Crate), 1)
                = Checks.Compiled,
              "a crate whose compiled unit matches a source was not judged");

      Fresh (Named);
      Put (Named & "/obj/named/named.ali", "V ""GNAT Lib v15""");
      Assert (Checks.Compiled_Anything (Named, "named"),
              "an object directory named after the crate was not read");
      Assert (not Checks.Compiled_Anything (Named),
              "a crate's own object directory was read without its name");
   end A_Crate_Compiled_Out_Of_Reach_Fails;

   --------------------------------------------------
   -- The_Tools_Are_Judged_Where_They_Were_Built --
   --------------------------------------------------

   --  The release checker's tools are judged by the repository checks only
   --  where they compiled anything: a native job that built the library
   --  and its tests has not, and the release checklist, which builds them,
   --  has.
   procedure The_Tools_Are_Judged_Where_They_Were_Built
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Root : constant String := Scratch & "/release-tree";
   begin
      Fresh (Root);
      Put (Root & "/tools/src/check_all.adb", "procedure Check_All is end;");
      Assert (not Checks.Compiled_Anything (Root & "/tools"),
              "tools that were never built read as built");

      Dirs.Create_Path (Root & "/tools/obj/development");
      Assert (not Checks.Compiled_Anything (Root & "/tools"),
              "an empty object directory for the tools read as a build");

      Put (Root & "/tools/obj/development/check_all.ali",
           "V ""GNAT Lib v15""");
      Assert (Checks.Compiled_Anything (Root & "/tools"),
              "tools that were built were not held to their evidence");
   end The_Tools_Are_Judged_Where_They_Were_Built;

   -----------------------------------------------------
   -- The_Breaking_Catalog_Line_Is_Found_Either_Way --
   -----------------------------------------------------

   --  The search for the line that stops a catalog loading finds a planted
   --  one in the real catalog, with its lines ended by line feeds and ended
   --  the Windows way, and names it without its line ending. On a CRLF
   --  checkout it named the header's first key, because the carriage
   --  returns were written back into every candidate twice.
   procedure The_Breaking_Catalog_Line_Is_Found_Either_Way
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Real  : constant String :=
        Text_Of ("../resources/messages/catalog.txt");
      Was   : constant String :=
        "en.error.backend.closed = the backend is closed";
      Fault : constant String := "en.error.backend.planted_fault";
      At_Was : constant Natural := Ada.Strings.Fixed.Index (Real, Was);

      --  The same text with a carriage return before every line feed.
      function Returned (Text : String) return String is
         Room : String (1 .. 2 * Text'Length);
         Used : Natural := 0;
      begin
         for Letter of Text loop
            if Letter = Character'Val (10) then
               Used := Used + 1;
               Room (Used) := Character'Val (13);
            end if;
            Used := Used + 1;
            Room (Used) := Letter;
         end loop;
         return Room (1 .. Used);
      end Returned;
   begin
      Assert (At_Was > 0, "the catalog no longer carries the line a fault "
              & "is planted beside");
      Fresh (Scratch & "/catalog");

      declare
         With_Fault : constant String :=
           Real (Real'First .. At_Was + Was'Length - 1)
           & Character'Val (10) & Fault
           & Real (At_Was + Was'Length .. Real'Last);
      begin
         Put (Scratch & "/catalog/lf.txt", With_Fault);
         Assert (Checks.Offending_Line
                   (Scratch & "/catalog/lf.txt",
                    Scratch & "/catalog/candidate.txt") = Fault,
                 "the planted line was not found in a catalog ended by "
                 & "line feeds");

         Put (Scratch & "/catalog/crlf.txt", Returned (With_Fault));
         Assert (Checks.Offending_Line
                   (Scratch & "/catalog/crlf.txt",
                    Scratch & "/catalog/candidate.txt") = Fault,
                 "the planted line was not found, or not without its line "
                 & "ending, in a catalog ended the Windows way");

         --  And the real catalog, both ways, loads: nothing to name.
         Put (Scratch & "/catalog/real-crlf.txt", Returned (Real));
         Assert (Checks.Offending_Line
                   (Scratch & "/catalog/real-crlf.txt",
                    Scratch & "/catalog/candidate.txt") = "",
                 "a catalog that loads was said to hold a breaking line "
                 & "when ended the Windows way");
      end;
   end The_Breaking_Catalog_Line_Is_Found_Either_Way;

   --  The specification holds as a gate: a matrix whose rows are all met,
   --  each by a test there is, passes; a row not met, a met row whose test
   --  is gone, or a specification changed since fails -- and the project's
   --  own matrix passes.
   procedure The_Specification_Is_A_Gate
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Root : constant String := Dirs.Full_Name ("obj/spec-gate");
      Spec : constant String := "The harness SHALL keep what it is told." & ASCII.LF;
      Head : constant String := "id" & ASCII.HT & "section" & ASCII.HT & "requirement" & ASCII.HT
        & "status" & ASCII.HT & "code" & ASCII.HT & "test" & ASCII.HT & "note" & ASCII.LF;

      procedure Row (Status, Test : String) is
      begin
         Put (Root & "/docs/spec-conformance.tsv",
              Head & "R1.1" & ASCII.HT & "1" & ASCII.HT & "keep it" & ASCII.HT & Status & ASCII.HT
              & "x.adb" & ASCII.HT & Test & ASCII.HT & "why" & ASCII.LF);
      end Row;
   begin
      Fresh (Root);
      Put (Root & "/docs/spec_driven_development_framework_v3_revised.md", Spec);
      Put (Root & "/docs/spec-conformance.sha1", GNAT.SHA1.Digest (Spec) & ASCII.LF);
      Put (Root & "/tests/src/a.adb",
           "procedure A is begin Assert (True, ""what it is " & """ & ""told is kept""); end A;");
      Row ("met", "what it is told is kept");
      Assert (Spec_Conformance.Problem (Root) = "",
              "a matrix met by its tests failed: " & Spec_Conformance.Problem (Root));
      Row ("partial", "what it is told is kept");
      Assert (Ada.Strings.Fixed.Index (Spec_Conformance.Problem (Root), "R1.1 is partial") > 0,
              "a requirement not met passed");
      Row ("met", "a test nobody wrote");
      Assert (Ada.Strings.Fixed.Index (Spec_Conformance.Problem (Root), "met by no test") > 0,
              "a requirement met by no test there is passed");
      Row ("met", "what it is told is kept");
      Put (Root & "/docs/spec_driven_development_framework_v3_revised.md", Spec & "More." & ASCII.LF);
      Assert (Ada.Strings.Fixed.Index (Spec_Conformance.Problem (Root), "has changed") > 0,
              "a specification changed since its rows were made passed");

      Assert (Spec_Conformance.Problem ("..") = "",
              "the project does not meet its specification: " & Spec_Conformance.Problem (".."));
   end The_Specification_Is_A_Gate;

   --  Two of the repository checks the suite runs too, being cheap and the
   --  two that let mistakes through on 2026-10-12: the build left no
   --  warnings in its logs, and no file of the tree -- builds, pinned
   --  crates' copies and history aside -- is past the two mebibytes the
   --  repository allows. A generated shader package passed it, and two
   --  style warnings stood in the library, and the suite said nothing.
   procedure The_Tree_Holds_Its_Two_Cheap_Bounds
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Dirs.File_Size;

      Root  : constant String := Dirs.Full_Name ("..");
      Limit : constant Dirs.File_Size := 2_097_152;
      Large : Natural := 0;
      First_Large : Ada.Strings.Unbounded.Unbounded_String;

      procedure Weigh (Directory : String) is
         Search : Dirs.Search_Type;
         Item   : Dirs.Directory_Entry_Type;
      begin
         Dirs.Start_Search (Search, Directory, "");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Item);
            declare
               Simple : constant String := Dirs.Simple_Name (Item);
               Full   : constant String := Dirs.Full_Name (Item);
            begin
               if Simple = "." or else Simple = ".." then
                  null;
               elsif Dirs."=" (Dirs.Kind (Item), Dirs.Directory) then
                  if Simple /= ".git" and then Simple /= "obj"
                    and then Simple /= "bin" and then Simple /= "alire"
                  then
                     Weigh (Full);
                  end if;
               elsif Dirs."=" (Dirs.Kind (Item), Dirs.Ordinary_File)
                 and then Dirs.Size (Item) > Limit
               then
                  Large := Large + 1;
                  if Large = 1 then
                     First_Large := Ada.Strings.Unbounded.To_Unbounded_String (Full);
                  end if;
               end if;
            end;
         end loop;
         Dirs.End_Search (Search);
      end Weigh;

      Quiet_Logs : Boolean := True;
   begin
      Weigh (Root);
      Assert (Large = 0,
              Natural'Image (Large) & " files are past two mebibytes, the first "
              & Ada.Strings.Unbounded.To_String (First_Large));

      begin
         Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr
           (Root & "/obj", Quiet => True);
         Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr
           (Root & "/tests/obj", Quiet => True);
      exception
         when others =>
            Quiet_Logs := False;
      end;
      Assert (Quiet_Logs,
              "the build left warnings behind; see the .stderr logs under obj "
              & "(a build older than its sources leaves old ones: build first)");
   end The_Tree_Holds_Its_Two_Cheap_Bounds;

   --  No frame of the library is a quarter of a megabyte. A task's stack
   --  is two megabytes unless it says otherwise, and a read buffer of four
   --  megabytes, a list's room of one at every level of a template, ran
   --  stacks out. The compiler writes each unit's frame sizes beside its
   --  object (-fstack-usage); every one under the library's object trees
   --  is read, and none found is a failure too: a build that stopped
   --  writing them would pass a gate that reads nothing.
   procedure No_Frame_Is_A_Quarter_Megabyte
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Most    : constant := 262_144;
      Read    : Natural := 0;
      Over    : Ada.Strings.Unbounded.Unbounded_String;

      procedure Look (Directory : String) is
         Search : Dirs.Search_Type;
         Item   : Dirs.Directory_Entry_Type;
      begin
         Dirs.Start_Search (Search, Directory, "");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Item);
            declare
               Simple : constant String := Dirs.Simple_Name (Item);
            begin
               if Simple in "." | ".." then
                  null;
               elsif Dirs."=" (Dirs.Kind (Item), Dirs.Directory) then
                  Look (Dirs.Full_Name (Item));
               elsif Simple'Length > 3 and then Simple (Simple'Last - 2 .. Simple'Last) = ".su" then
                  Read := Read + 1;
                  declare
                     File : Ada.Text_IO.File_Type;
                  begin
                     Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Dirs.Full_Name (Item));
                     while not Ada.Text_IO.End_Of_File (File) loop
                        declare
                           Line  : constant String := Ada.Text_IO.Get_Line (File);
                           First : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
                           Second : constant Natural :=
                             (if First = 0 then 0
                              else Ada.Strings.Fixed.Index (Line (First + 1 .. Line'Last), [1 => ASCII.HT]));
                        begin
                           if Second > First + 1
                             and then Natural'Value (Line (First + 1 .. Second - 1)) >= Most
                           then
                              Ada.Strings.Unbounded.Append (Over, ASCII.LF & "  " & Line);
                           end if;
                        end;
                     end loop;
                     Ada.Text_IO.Close (File);
                  end;
               end if;
            end;
         end loop;
         Dirs.End_Search (Search);
      end Look;
   begin
      Look (Dirs.Full_Name ("../obj"));
      Assert (Read > 0, "no frame sizes were written under obj: the library is to be built with -fstack-usage");
      Assert (Ada.Strings.Unbounded.Length (Over) = 0,
              "frames of a quarter of a megabyte or more -- hold what makes them so on the heap"
              & " (Model_Runner.Heap_Buffers):" & Ada.Strings.Unbounded.To_String (Over));
   end No_Frame_Is_A_Quarter_Megabyte;

   --  A run narrowed to a name no test begins with ran none and says
   --  so, where it said passed: "backend" for "cpu backend".
   procedure A_Name_Matching_No_Test_Is_Not_A_Pass
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Suite_Filter.Verdict;
   begin
      Assert (Suite_Filter.Judge (0, True, "backend")
                = Suite_Filter.Matched_None,
              "a name that ran no test passed");
      Assert (Suite_Filter.Judge (85, True, "cpu backend")
                = Suite_Filter.Passed,
              "a name that ran its tests, all passing, did not pass");
      Assert (Suite_Filter.Judge (85, False, "cpu backend")
                = Suite_Filter.Failed,
              "a name whose tests failed did not fail");
      Assert (Suite_Filter.Judge (0, True, "") = Suite_Filter.Passed,
              "an unnarrowed run of nothing failed");
   end A_Name_Matching_No_Test_Is_Not_A_Pass;

   --------------------
   -- Register_Tests --
   --------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Tree_Holds_Its_Two_Cheap_Bounds'Access,
         "the build left no warnings and no file of the tree is past two "
         & "mebibytes");
      Register_Routine
        (T, A_Name_Matching_No_Test_Is_Not_A_Pass'Access,
         "a run narrowed to a name no test begins with fails, rather than "
         & "passing over nothing");
      Register_Routine
        (T, No_Frame_Is_A_Quarter_Megabyte'Access,
         "no frame of the library is a quarter of a megabyte, so a task's stack holds a chain of them");
      Register_Routine
        (T, The_Specification_Is_A_Gate'Access,
         "the specification is a gate: every requirement met, by a test there is");
      Register_Routine
        (T, Short_Sweep_Crosses_Binary32_Alone'Access,
         "the short conformance sweep crosses binary32 weights alone, on "
         & "both arms, and the full sweep every format");
      Register_Routine
        (T, Accounting_Holds_To_What_Was_Asked_For'Access,
         "a conformance sweep is held to the comparisons it asked for, and "
         & "one lost without a word fails it");
      Register_Routine
        (T, A_Prepared_Crate_That_Compiled_Nothing_Is_Said'Access,
         "a pinned crate with an object directory and nothing compiled in "
         & "it is said to be unbuilt, not failed");
      Register_Routine
        (T, A_Crate_Compiled_Out_Of_Reach_Fails'Access,
         "a pinned crate that compiled units matching none of its sources "
         & "fails, and one whose units match is judged");
      Register_Routine
        (T, The_Tools_Are_Judged_Where_They_Were_Built'Access,
         "the release checker's tools are held to compilation evidence "
         & "where they were built and not where they were not");
      Register_Routine
        (T, The_Breaking_Catalog_Line_Is_Found_Either_Way'Access,
         "the line that breaks a catalog is found with its lines ended by "
         & "line feeds and ended the Windows way");
   end Register_Tests;

end Tests.Gate_Cases;
