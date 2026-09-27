with AUnit.Assertions; use AUnit.Assertions;

with Ada.Directories;
with Ada.Strings.Fixed;

with Project_Tools.Files;

with Checks;
with Conformance;
with Tiny_Model;

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

   --------------------
   -- Register_Tests --
   --------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
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
