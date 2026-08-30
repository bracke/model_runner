with Ada.Calendar;
with Ada.Directories;
with Ada.Text_IO;
with Interfaces;
use type Interfaces.Unsigned_64;

with Hostkit.Fs;

with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Project_Tools.Ada_Source;
with Project_Tools.Processes;
with Project_Tools.Files;
with Project_Tools.Text;
with Project_Tools.Tree_Checks;

with Docs_Generation;
with Library_Surface;
with Reserved_Codes;
with Unreached_Codes;
with Untested_Surface;
with Template_Registry;
with Tiny_Model;
with Model_Runner.Platform.Device.Products;
with Model_Runner.Shaders;
with Shader_Generation;
with Tool_Commands;

with Model_Runner;
with Model_Runner.Errors;
with Model_Runner.Backend;
with Model_Runner.Backend.CPU;
with Model_Runner.CLI.Interactive;
with Model_Runner.CLI.Options;
with Model_Runner.GGUF;
with Model_Runner.Generation;
with Model_Runner.Llama;
with Model_Runner.Localization;
with Model_Runner.Progress;
with Model_Runner.Quantization;
with Model_Runner.Templates;
with Model_Runner.Text;

package body Checks is

   use type Model_Runner.Errors.Error_Code;
   use type Template_Registry.Outcome;
   use type Template_Registry.Text_Access;

   package Dirs renames Ada.Directories;
   package E renames Model_Runner.Errors;
   package Opt renames Model_Runner.CLI.Options;

   use type Opt.Command_Kind;
   use type Model_Runner.CLI.Interactive.Command_Kind;
   package Files renames Project_Tools.Files;
   package T renames Model_Runner.Text;

   Max_Line : constant := 120;

   ---------
   -- Run --
   ---------

   procedure Run
     (Root             : String;
      Result           : out Report;
      Record_Warnings  : Boolean := False)
   is

      procedure Fail (Detail : String) is
      begin
         Result.Failed := Result.Failed + 1;
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "  fail: " & Detail);
      end Fail;

      --  A body that is part of another unit rather than one of its own.
      --
      --  A subunit is compiled into its parent and has no .ali of its own,
      --  so asking for one would report four perfectly ordinary files in a
      --  pinned crate as never compiled. It is recognized the way the
      --  language defines it: the first thing that is not a comment or blank
      --  is the word separate.
      function Is_Subunit (Path : String) return Boolean is
         Handle : Ada.Text_IO.File_Type;
         Answer : Boolean := False;
      begin
         Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Path);
         while not Ada.Text_IO.End_Of_File (Handle) loop
            declare
               Line : constant String :=
                 Ada.Strings.Fixed.Trim
                   (Ada.Text_IO.Get_Line (Handle), Ada.Strings.Both);
            begin
               if Line'Length = 0
                 or else (Line'Length >= 2
                          and then Line (Line'First .. Line'First + 1) = "--")
               then
                  null;
               else
                  Answer :=
                    Line'Length >= 9
                    and then Line (Line'First .. Line'First + 8) = "separate ";
                  exit;
               end if;
            end;
         end loop;
         Ada.Text_IO.Close (Handle);
         return Answer;
      exception
         when others =>
            if Ada.Text_IO.Is_Open (Handle) then
               Ada.Text_IO.Close (Handle);
            end if;
            return False;
      end Is_Subunit;

      --  How many noisy compilations a pinned crate is recorded as having.
      --
      --  Minus one when it is not recorded at all, which is a failure rather
      --  than a zero: an unrecorded crate is one nobody has looked at, and
      --  saying so is the point.
      function Recorded_Warnings (Name : String) return Integer is
         Path   : constant String := Root & "/docs/dependency-warnings.txt";
         Handle : Ada.Text_IO.File_Type;
         Answer : Integer := -1;
      begin
         if not Ada.Directories.Exists (Path) then
            return -1;
         end if;

         Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Path);
         while not Ada.Text_IO.End_Of_File (Handle) loop
            declare
               Line : constant String :=
                 Ada.Strings.Fixed.Trim
                   (Ada.Text_IO.Get_Line (Handle), Ada.Strings.Both);
               Space : Natural;
            begin
               if Line'Length > 0 and then Line (Line'First) /= '#' then
                  Space := Ada.Strings.Fixed.Index (Line, " ");
                  if Space > Line'First
                    and then Line (Line'First .. Space - 1) = Name
                  then
                     Answer :=
                       Integer'Value
                         (Ada.Strings.Fixed.Trim
                            (Line (Space .. Line'Last), Ada.Strings.Both));
                     exit;
                  end if;
               end if;
            end;
         end loop;
         Ada.Text_IO.Close (Handle);
         return Answer;
      exception
         when others =>
            if Ada.Text_IO.Is_Open (Handle) then
               Ada.Text_IO.Close (Handle);
            end if;
            return -1;
      end Recorded_Warnings;

      --  Whether another file in this tree carries the same unit name.
      --
      --  A unit with a body per platform has one: src/platform/posix and
      --  src/platform/windows both hold model_runner-platform-signals.adb,
      --  and only the one for this host is compiled. They share an object
      --  file name, so the body that was not compiled finds the other one's
      --  object and is judged against its own modification time -- which
      --  reported a Windows body somebody had edited as evidence that this
      --  build was stale. It was evidence of nothing: that file is not in
      --  this build.
      --
      --  Nothing here can tell which of the two was compiled, because the
      --  object file records the source's name and not its path. So a unit
      --  with more than one candidate is not judged at all, and that is
      --  said rather than assumed.
      function Has_Twin (Place, Path : String) return Boolean is
         Wanted : constant String := Ada.Directories.Simple_Name (Path);
         Found  : Boolean := False;

         procedure Walk (Where : String) is
            Search : Ada.Directories.Search_Type;
            Item   : Ada.Directories.Directory_Entry_Type;
         begin
            if Found or else not Ada.Directories.Exists (Where) then
               return;
            end if;

            Ada.Directories.Start_Search
              (Search, Where, "",
               [Ada.Directories.Ordinary_File => True,
                Ada.Directories.Directory => True,
                others => False]);
            while Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Item);
               declare
                  Simple : constant String :=
                    Ada.Directories.Simple_Name (Item);
                  Full : constant String := Ada.Directories.Full_Name (Item);
               begin
                  if Simple /= "." and then Simple /= ".."
                    and then Simple /= "obj" and then Simple /= ".git"
                  then
                     if Ada.Directories."="
                          (Ada.Directories.Kind (Item),
                           Ada.Directories.Directory)
                     then
                        Walk (Full);
                     elsif Simple = Wanted and then Full /= Path then
                        Found := True;
                     end if;
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (Search);
         end Walk;
      begin
         Walk (Place);
         return Found;
      end Has_Twin;

      --  The words at the top of docs/dependency-warnings.txt, written by
      --  the tool that writes the counts so that the file cannot end up
      --  explaining itself in terms that have stopped being true.
      procedure Write_Preamble (Into : Ada.Text_IO.File_Type) is
         procedure Say (Text : String) is
         begin
            Ada.Text_IO.Put_Line (Into, Text);
         end Say;
      begin
         Say ("# What the crates this build is pinned to compile with.");
         Say ("#");
         Say ("# Written by `tests check --record-warnings`. Every "
              & "dependency here is");
         Say ("# pinned to a sibling working tree, so a build of this "
              & "program compiles");
         Say ("# those trees as surely as it compiles this one. Their "
              & "warnings are not");
         Say ("# this repository's to fix -- a gate that went red for a "
              & "sibling crate's");
         Say ("# warning would pass on one machine and on no other, and "
              & "would put this");
         Say ("# project's release behind somebody else's tidying.");
         Say ("#");
         Say ("# What this file does is stop them being wallpaper. "
              & "Sixty-three warnings");
         Say ("# listed every run are sixty-three warnings nobody reads, "
              & "and the");
         Say ("# sixty-fourth arrives invisible among them. So the count "
              & "is written down,");
         Say ("# and `tests check` refuses a crate that has more than is "
              & "recorded here,");
         Say ("# or one with warnings that is not recorded at all. A "
              & "crate that gets");
         Say ("# tidier is reported so the number can come down.");
         Say ("#");
         Say ("# The count is of compilations that said something, not of "
              & "warnings: one");
         Say ("# compilation can say a dozen things. That is what a "
              & ".stderr log beside an");
         Say ("# object file counts as, and it is the number the check "
              & "can see.");
         Say ("#");
         Say ("# A crate at zero is listed too, because absent and quiet "
              & "have to be");
         Say ("# different things here: an unlisted crate is one nobody "
              & "has looked at.");
         Say ("#");
         Say ("# Format, one crate a line:");
         Say ("#   <crate> <compilations that left warnings>");
         Say ("");
      end Write_Preamble;

      procedure Check (Condition : Boolean; Detail : String) is
      begin
         Result.Performed := Result.Performed + 1;
         if not Condition then
            Fail (Detail);
         end if;
      end Check;

      --  Sixteen hex digits, upper case, of a 64-bit value.
      function Hex (Value : Interfaces.Unsigned_64) return String is
         Digits_Text : constant String := "0123456789ABCDEF";
         Result_Text : String (1 .. 16);
         Left        : Interfaces.Unsigned_64 := Value;
      begin
         for Index in reverse Result_Text'Range loop
            Result_Text (Index) :=
              Digits_Text
                (Digits_Text'First + Natural (Left and 16#F#));
            Left := Interfaces.Shift_Right (Left, 4);
         end loop;
         return Result_Text;
      end Hex;

      function Path (Parts : String) return String
      is (Hostkit.Fs.Join (Root, Parts));

      --  Read a file, or an empty string when it is not there.
      --
      --  Carriage returns come off. A checkout on a host whose line ending
      --  is two characters gives them back that way, and every check here
      --  measures or matches what it reads: the 120-character budget would
      --  count the extra character and fail every source that reaches
      --  exactly 120, and a comparison against a literal would miss. The
      --  command-line tests lost four to this on Windows before it was
      --  found; these run on one host today and would have lost more the
      --  moment they ran on another.
      function Contents (Relative : String) return String is
      begin
         if Files.File_Exists (Path (Relative)) then
            declare
               Whole : constant String :=
                 Files.Read_Raw_File (Path (Relative));
               Room  : String (1 .. Whole'Length);
               Used  : Natural := 0;
            begin
               for Character_Value of Whole loop
                  if Character_Value /= Character'Val (13) then
                     Used := Used + 1;
                     Room (Used) := Character_Value;
                  end if;
               end loop;

               return Room (1 .. Used);
            end;
         else
            return "";
         end if;
      end Contents;

      --  Which line stops a catalog loading, found by halving.
      --
      --  The runtime refuses a catalog whole: one line it cannot compile and
      --  nothing renders, in any locale, with no indication of where. A
      --  placeholder named seconds does it, which took a bisection by hand
      --  to find and is the reason this exists -- the next one should cost
      --  nobody an afternoon.
      --
      --  Halving rather than one line at a time, because each attempt
      --  compiles a whole catalog: eleven opens against eleven hundred. The
      --  header goes into every candidate, and a candidate that is missing
      --  most of its keys still loads, which is what makes the search
      --  possible at all.
      --
      --  @param Source Catalog to search.
      --  @param Scratch Where to write candidates.
      --  @return The offending line, or the empty string when the catalog
      --    loads or when no single line accounts for it.
      function Offending_Line (Source, Scratch : String) return String is
         --  Read directly rather than through Contents, which takes a path
         --  relative to the repository and would look for this one inside
         --  itself. That silently returned nothing, and the search returned
         --  nothing with it -- which looked exactly like a catalog with no
         --  single line to blame.
         Text : constant String :=
           (if Files.File_Exists (Source)
            then Files.Read_Raw_File (Source) else "");

         --  Every line, as start and stop offsets into Text.
         type Span is record
            From, To : Natural := 0;
         end record;

         Lines : array (1 .. 4096) of Span;
         Count : Natural := 0;

         --  The header this catalog needs whatever else is dropped.
         Header : Natural := 0;

         procedure Split is
            At_Byte : Natural := Text'First;
         begin
            while At_Byte <= Text'Last loop
               declare
                  Stop : Natural := At_Byte;
               begin
                  while Stop <= Text'Last
                    and then Text (Stop) /= Character'Val (10)
                  loop
                     Stop := Stop + 1;
                  end loop;

                  if Count < Lines'Last then
                     Count := Count + 1;
                     Lines (Count) := (At_Byte, Stop - 1);
                  end if;
                  At_Byte := Stop + 1;
               end;
            end loop;
         end Split;

         --  Whether the catalog made of the header plus lines First .. Last
         --  refuses to load.
         function Refuses (First, Last : Natural) return Boolean is
            Handle : Ada.Text_IO.File_Type;
            Held   : Model_Runner.Localization.Catalog;
            Answer : Boolean;
         begin
            Ada.Text_IO.Create (Handle, Ada.Text_IO.Out_File, Scratch);
            for Index in 1 .. Header loop
               Ada.Text_IO.Put_Line
                 (Handle, Text (Lines (Index).From .. Lines (Index).To));
            end loop;
            for Index in First .. Last loop
               Ada.Text_IO.Put_Line
                 (Handle, Text (Lines (Index).From .. Lines (Index).To));
            end loop;
            Ada.Text_IO.Close (Handle);

            Model_Runner.Localization.Open (Held, Scratch, "en");
            Answer := not Model_Runner.Localization.Is_Ready (Held);
            Model_Runner.Localization.Close (Held);
            return Answer;
         end Refuses;

         Low, High : Natural;
      begin
         if Text'Length = 0 then
            return "";
         end if;

         Split;

         --  The header is everything before the first locale entry, which is
         --  where default_locale is stated.
         while Header < Count
           and then not Project_Tools.Text.Contains
                          (Text (Lines (Header + 1).From
                                 .. Lines (Header + 1).To), "en.")
         loop
            Header := Header + 1;
         end loop;

         Low := Header + 1;
         High := Count;

         if not Refuses (Low, High) then
            return "";
         end if;

         --  Halve while one half still refuses on its own. When neither
         --  does, the two lines that disagree are in different halves and
         --  this cannot name one -- which is said by returning nothing
         --  rather than by naming the wrong line.
         while High > Low loop
            declare
               Middle : constant Natural := Low + (High - Low) / 2;
            begin
               if Refuses (Low, Middle) then
                  High := Middle;
               elsif Refuses (Middle + 1, High) then
                  Low := Middle + 1;
               else
                  return "";
               end if;
            end;
         end loop;

         return Text (Lines (Low).From .. Lines (Low).To);
      end Offending_Line;

      --  One section of a document, from its heading to the next one.
      --  The heading must end at its line: "## Backend" is a prefix of
      --  "## Backends and pools", and matching the prefix let that section be
      --  renamed without anything noticing.
      function Section (Text, Heading : String) return String is
         Opening : constant String := Heading & Character'Val (10);
         From    : Natural := 0;
      begin
         if Text'Length < Opening'Length then
            return "";
         end if;
         for Index in Text'First .. Text'Last - Opening'Length + 1 loop
            if Text (Index .. Index + Opening'Length - 1) = Opening then
               From := Index + Opening'Length;
               exit;
            end if;
         end loop;
         if From = 0 then
            return "";
         end if;
         for Index in From .. Text'Last - 2 loop
            if Text (Index) = Character'Val (10)
              and then Text (Index + 1 .. Index + 2) = "##"
            then
               return Text (From .. Index);
            end if;
         end loop;
         return Text (From .. Text'Last);
      end Section;

      --  Report whether text holds a token.
      function Holds (Text, Token : String) return Boolean
      is (Project_Tools.Text.Contains (Text, Token));

      --  Report whether a file mentions a token. A file that is not there
      --  mentions nothing, which is what Contents already says.
      function Mentions (Relative, Token : String) return Boolean
      is (Project_Tools.Text.Contains (Contents (Relative), Token));

      --  Visit every Ada source under a directory.
      generic
         with procedure Visit (Relative : String);
      procedure For_Each_Source (Directory : String);

      --  Every source beneath a directory, however deep.
      --
      --  This used to search one level, so a caller had to name every host
      --  directory: three of the five were named, and the two holding the
      --  bodies that actually run were not. Worse, three scans were given
      --  src/platform, which holds no sources of its own -- they visited
      --  nothing and reported nothing, which is indistinguishable from
      --  finding nothing wrong. A caller names a root now and the walk finds
      --  what is under it, so there is no list of directories to keep and
      --  none to get wrong.
      procedure For_Each_Source (Directory : String) is

         --  The path a check sees, with one separator on every host.
         --
         --  Hostkit.Fs.Join joins the host's way, so on Windows a check was
         --  handed "tests\src\checks.adb" and compared it against
         --  "tests/src/checks.adb". Every comparison of that shape silently
         --  stopped matching: the registries excluded themselves from the
         --  scan that reads them, so every code they name read as named by a
         --  test, and nine were reported as reached that nothing reaches.
         --  Forward slashes are accepted for opening a file on both hosts,
         --  so the normalized form is the one that travels.
         function As_Written (Item : String) return String is
            Room : String := Item;
         begin
            for Index in Room'Range loop
               if Room (Index) = '\' then
                  Room (Index) := '/';
               end if;
            end loop;

            return Room;
         end As_Written;

         procedure Walk (Where : String) is
            Search : Dirs.Search_Type;
            Item   : Dirs.Directory_Entry_Type;
         begin
            if not Files.Directory_Exists (Path (Where)) then
               return;
            end if;

            Dirs.Start_Search
              (Search, Path (Where), "*.ad[sb]",
               [Dirs.Ordinary_File => True, others => False]);

            while Dirs.More_Entries (Search) loop
               Dirs.Get_Next_Entry (Search, Item);
               Visit
                 (As_Written (Hostkit.Fs.Join (Where, Dirs.Simple_Name (Item))));
            end loop;

            Dirs.End_Search (Search);

            --  Then the directories below, which is where the host bodies
            --  live.
            Dirs.Start_Search
              (Search, Path (Where), "",
               [Dirs.Directory => True, others => False]);

            while Dirs.More_Entries (Search) loop
               Dirs.Get_Next_Entry (Search, Item);
               declare
                  Name : constant String := Dirs.Simple_Name (Item);
               begin
                  if Name /= "." and then Name /= ".." then
                     Walk (Hostkit.Fs.Join (Where, Name));
                  end if;
               end;
            end loop;

            Dirs.End_Search (Search);
         end Walk;
      begin
         Walk (Directory);
      end For_Each_Source;

   begin
      Result := (others => <>);
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "repository checks");

      --  Crate structure.
      Check (Files.File_Exists (Path ("alire.toml")),
             "the root crate manifest is missing");
      Check (Files.File_Exists (Path ("model_runner.gpr")),
             "the root project file is missing");
      Check (Files.File_Exists (Path ("tests/alire.toml")),
             "the tests crate manifest is missing");
      Check (Files.File_Exists (Path ("tests/tests.gpr")),
             "the tests project file is missing");
      Check (Files.File_Exists (Path ("LICENSE")), "LICENSE is missing");
      Check (Files.File_Exists (Path ("README.md")), "README.md is missing");
      Check (Files.File_Exists (Path ("CHANGELOG.md")), "CHANGELOG.md is missing");
      Check (Files.File_Exists (Path ("SECURITY.md")), "SECURITY.md is missing");
      Check (Files.File_Exists (Path ("CONTRIBUTING.md")),
             "CONTRIBUTING.md is missing");
      Check (Files.File_Exists (Path ("resources/messages/catalog.txt")),
             "the message catalog is missing");

      --  Declared dependencies.
      Check (Mentions ("alire.toml", "name = ""model_runner"""),
             "the root crate is not named model_runner");
      Check (Mentions ("alire.toml", "executables = [""model_runner""]"),
             "the root crate does not declare the model_runner executable");
      Check (Mentions ("alire.toml", "terminal_styles"),
             "the root crate does not depend on terminal_styles");
      Check (Mentions ("alire.toml", "messages"),
             "the root crate does not depend on messages");
      Check (Mentions ("tests/alire.toml", "name = ""tests"""),
             "the tests crate is not named tests");
      Check (Mentions ("tests/alire.toml", "executables = [""tests""]"),
             "the tests crate does not declare the tests executable");
      Check (Mentions ("tests/alire.toml", "aunit"),
             "the tests crate does not depend on aunit");
      Check (Mentions ("tests/alire.toml", "project_tools"),
             "the tests crate does not depend on project_tools");
      Check (Mentions ("tests/alire.toml", "model_runner"),
             "the tests crate does not depend on model_runner");

      --  Version agreement between the manifest and the code.
      Check (Mentions ("alire.toml", "version = """ & Model_Runner.Version & """"),
             "alire.toml and Model_Runner.Version disagree");

      --  No scripting-language tooling anywhere the repository owns.
      declare
         procedure Reject (Name : String) is
         begin
            Check (not Files.File_Exists (Path (Name)),
                   Name & " is a scripting-language build file");
         end Reject;
      begin
         Reject ("build.sh");
         Reject ("run.sh");
         Reject ("test.sh");
         Reject ("Makefile");
         Reject ("makefile");
         Reject ("CMakeLists.txt");
         Reject ("setup.py");
         Reject ("package.json");
         Reject ("build.bat");
         Reject ("tests/build.sh");
         Reject ("tests/Makefile");
      end;

      --  Layering: production code must not reach the test crate or its
      --  dependencies.
      declare
         None : constant Project_Tools.Ada_Source.String_List (1 .. 0) :=
           [others => Ada.Strings.Unbounded.Null_Unbounded_String];

         --  Nothing under these prefixes is allowed, which is what an empty
         --  allowlist says. project_tools parses the with clauses rather than
         --  looking for the text of one, so a limited with, a private with or
         --  two units on one line are read as clauses instead of missed.
         procedure Forbid_Prefix (Relative, Prefix, Detail : String) is
         begin
            Result.Performed := Result.Performed + 1;

            begin
               Project_Tools.Ada_Source.Require_Only_Allowed_With_Clauses
                 (Source_Path => Path (Relative),
                  Prefix      => Prefix,
                  Allowed     => None);
            exception
               when others =>
                  Fail (Relative & " depends on " & Detail);
            end;
         end Forbid_Prefix;

         procedure Visit_Production (Relative : String) is
         begin
            Forbid_Prefix (Relative, "AUnit", "AUnit");
            Forbid_Prefix (Relative, "Project_Tools", "project_tools");
            Forbid_Prefix (Relative, "Tests", "the tests crate");
         end Visit_Production;

         procedure Scan_Production is
           new For_Each_Source (Visit_Production);
      begin
         --  Every host body too: each is production code held to the same
         --  rules, and left out, one could reach a forbidden layer and
         --  nothing would say so. They used to be named one directory at a
         --  time and two of the five were not on the list, which is why the
         --  walk goes down from the root instead.
         Scan_Production ("src");
      end;

      --  Ordinary Ada, all the way down.
      --
      --  Machine code is not refused here.
      --
      --  A check used to fail the build on any use of System.Machine_Code,
      --  in a project written in Ada, where machine code insertions are an
      --  Ada feature. It guarded a sentence in the README rather than
      --  anything about the program, and forbidding a language's own
      --  facility is not a property worth holding: what keeps another
      --  language out of this repository is the check above, on the sources
      --  themselves, which is a different question and still asked.

      --  Layering: nothing below the presentation layer may reach the message
      --  catalog, terminal styling or the command line.
      declare
         procedure Visit_Lower (Relative : String) is
            Name : constant String := T.To_Lower (Relative);
            Upper : constant Boolean :=
              T.Starts_With (Name, "src/library/model_runner-cli")
              or else T.Starts_With (Name, "src/library/model_runner-presentation")
              or else T.Starts_With (Name, "src/library/model_runner-localization")
              or else T.Starts_With (Name, "src/main/");
         begin
            if Upper then
               return;
            end if;

            Result.Performed := Result.Performed + 1;

            if Mentions (Relative, "with Messages") then
               Fail (Relative & " reaches the message catalog");
            elsif Mentions (Relative, "with Terminal_Styles") then
               Fail (Relative & " reaches terminal styling");
            elsif Mentions (Relative, "with Model_Runner.CLI") then
               Fail (Relative & " reaches the command-line layer");
            elsif Mentions (Relative, "with Model_Runner.Presentation") then
               Fail (Relative & " reaches the presentation layer");
            elsif Mentions (Relative, "with Ada.Text_IO")
              and then not T.Starts_With
                             (Name, "src/library/model_runner-platform")
              and then not T.Starts_With (Name, "src/platform/")
            then
               Fail (Relative & " writes to a standard stream");
            end if;
         end Visit_Lower;

         procedure Scan_Lower is new For_Each_Source (Visit_Lower);
      begin
         Scan_Lower ("src");
      end;

      --  Style: the documented line-length budget.
      declare
         Files_Seen : Natural := 0;

         procedure Visit_Length (Relative : String) is
            Text  : constant String := Contents (Relative);
            Width : Natural := 0;
            Worst : Natural := 0;
         begin
            Result.Performed := Result.Performed + 1;
            for Char of Text loop
               if Char = ASCII.LF then
                  Worst := Natural'Max (Worst, Width);
                  Width := 0;
               else
                  Width := Width + 1;
               end if;
            end loop;
            Worst := Natural'Max (Worst, Width);
            Files_Seen := Files_Seen + 1;

            if Worst > Max_Line then
               Fail (Relative & " has a line of" & Natural'Image (Worst)
                     & " characters");
            end if;
         end Visit_Length;

         procedure Scan_Length is new For_Each_Source (Visit_Length);

         --  Every Ada source in the repository passes through here, so this
         --  is where the walk itself is held to finding them.
         --
         --  A scan that visits nothing reports nothing, and nothing is what
         --  a clean run looks like. Three scans were handed a directory that
         --  holds only subdirectories and were silent for it; the walk goes
         --  down from a root now, and this fails if it ever stops arriving
         --  anywhere. The floor is well under the count so that adding or
         --  removing a source is not an event, and well over zero so that a
         --  walk that finds a fraction of the tree cannot pass.
         Fewest_Sources : constant := 120;
      begin
         Scan_Length ("src");
         Scan_Length ("tests/src");
         Scan_Length ("tools/src");

         Result.Performed := Result.Performed + 1;
         if Files_Seen < Fewest_Sources then
            Fail ("the source walk visited" & Natural'Image (Files_Seen)
                  & " files, fewer than the" & Natural'Image (Fewest_Sources)
                  & " this repository has; it is no longer reaching the tree");
         end if;
      end;

      --  Documentation: every public specification opens with a comment.
      declare
         procedure Visit_Doc (Relative : String) is
         begin
            if not T.Ends_With (Relative, ".ads") then
               return;
            end if;

            Result.Performed := Result.Performed + 1;

            --  project_tools reads the declarations and requires a tag for
            --  each part of a public profile, which is more than this file
            --  used to ask -- it wanted a comment, anywhere.
            --
            --  It reports by naming the declaration and then raising, which
            --  would end the run at the first spec with a gap and hide every
            --  check after it. Caught here so the run finishes and the total
            --  counts this like anything else; the exit status it has already
            --  set stands whatever this file goes on to find.
            begin
               Project_Tools.Ada_Source.Require_Public_GNATdoc_Tags
                 (Spec_Path => Path (Relative));
            exception
               when others =>
                  Fail (Relative & " has a public declaration without its "
                        & "GNATdoc tags");
            end;
         end Visit_Doc;

         procedure Scan_Doc is new For_Each_Source (Visit_Doc);
      begin
         Scan_Doc ("src");
         Scan_Doc ("tests/src");
         Scan_Doc ("tools/src");
      end;

      --  Diagnostic registry: every code has a catalog entry. The catalog file
      --  is read directly here so that the check does not depend on the
      --  message runtime.
      declare
         Catalog : constant String := Contents ("resources/messages/catalog.txt");

         function Has_Key (Key : String) return Boolean is
            Needle : constant String := "en." & Key & " =";
         begin
            if Catalog'Length < Needle'Length then
               return False;
            end if;
            for Index in Catalog'First .. Catalog'Last - Needle'Length + 1 loop
               if Catalog (Index .. Index + Needle'Length - 1) = Needle then
                  return True;
               end if;
            end loop;
            return False;
         end Has_Key;
      begin
         for Code in E.Error_Code loop
            if Code /= E.No_Error then
               Result.Performed := Result.Performed + 1;
               if not Has_Key (E.Message_Key (Code)) then
                  Fail ("no catalog entry for " & E.Message_Key (Code));
               end if;
            end if;
         end loop;
      end;

      --  Every catalog key has a reader.
      --
      --  Every other registry in this repository is asked of the code: an
      --  enumeration value with no reader fails, a public operation with no
      --  caller fails, a documented row with no code behind it fails. The
      --  catalog was the last one nobody asked. Ten keys had no reader at
      --  all, and three of them read as capability rather than cruft --
      --  "backend" and "worker tasks" were labels for figures the program
      --  never printed, and "the model has no chat template; the prompt is
      --  being sent unchanged" described a silent fallback the program
      --  refuses to make. They were carried in three locales.
      --
      --  A key is reachable one of two ways. Most are written where they are
      --  used, so the literal appears in a source. The rest are built from an
      --  enumeration -- a diagnostic, a completion reason, a progress stage --
      --  and those are constructed here the same way the code constructs
      --  them, so a stage that gains a value needs a key and a key whose
      --  stage is gone has nobody to answer for it.
      declare
         Catalog : constant String :=
           Contents ("resources/messages/catalog.txt");

         Room  : constant := 512;
         Width : constant := 96;

         type Key_Text is record
            Text : String (1 .. Width) := [others => ' '];
            Last : Natural := 0;
            Read : Boolean := False;
         end record;

         Keys  : array (1 .. Room) of Key_Text;
         Count : Natural := 0;

         --  Mark a key as reached, by whatever reached it.
         procedure Reached (Key : String) is
         begin
            for Index in 1 .. Count loop
               if Keys (Index).Text (1 .. Keys (Index).Last) = Key then
                  Keys (Index).Read := True;
               end if;
            end loop;
         end Reached;

         --  Mark every key a source names as a literal.
         procedure Visit_Keys (Relative : String) is
            Text : constant String := Contents (Relative);
         begin
            for Index in 1 .. Count loop
               if not Keys (Index).Read
                 and then Holds
                            (Text,
                             '"' & Keys (Index).Text (1 .. Keys (Index).Last)
                             & '"')
               then
                  Keys (Index).Read := True;
               end if;
            end loop;
         end Visit_Keys;

         procedure Scan_Keys is new For_Each_Source (Visit_Keys);

         Cursor : Natural := Catalog'First;
      begin
         --  The English keys are the catalog: another locale carries a
         --  subset and falls back, so a key it does not have is not missing.
         while Cursor <= Catalog'Last loop
            declare
               Stop : Natural := Cursor;
            begin
               while Stop <= Catalog'Last
                 and then Catalog (Stop) /= Character'Val (10)
               loop
                  Stop := Stop + 1;
               end loop;

               declare
                  Line : constant String := Catalog (Cursor .. Stop - 1);
               begin
                  if Line'Length > 3
                    and then Line (Line'First .. Line'First + 2) = "en."
                  then
                     for Index in Line'First + 3 .. Line'Last loop
                        if Line (Index) = ' ' then
                           declare
                              Key : constant String :=
                                Line (Line'First + 3 .. Index - 1);
                           begin
                              if Count < Room and then Key'Length <= Width then
                                 Count := Count + 1;
                                 Keys (Count).Last := Key'Length;
                                 Keys (Count).Text (1 .. Key'Length) := Key;
                              end if;
                           end;
                           exit;
                        end if;
                     end loop;
                  end if;
               end;

               Cursor := Stop + 1;
            end;
         end loop;

         Result.Performed := Result.Performed + 1;
         if Count = 0 then
            Fail ("no catalog keys were found; the check no longer matches "
                  & "the file it reads");
         end if;

         --  The three families the code builds rather than writes.
         for Code in E.Error_Code loop
            if Code /= E.No_Error then
               Reached (E.Message_Key (Code));
            end if;
         end loop;

         for Reason in Model_Runner.Generation.Completion_Reason loop
            Reached
              ("completion." & Model_Runner.Generation.Reason_Name (Reason));
         end loop;

         for Stage in Model_Runner.Progress.Load_Stage loop
            Reached
              ("progress.loading."
               & T.To_Lower (Model_Runner.Progress.Load_Stage'Image (Stage)));
         end loop;

         for Stage in Model_Runner.Progress.Generation_Stage loop
            Reached
              ("progress.generation."
               & T.To_Lower
                   (Model_Runner.Progress.Generation_Stage'Image (Stage)));
         end loop;

         --  A fourth family: a help line per option per command that takes
         --  it, built where the help screen is written rather than named
         --  there. The registry says which those are.
         --  Over every command rather than the two that had options when
         --  this was written: a third arrived and each of its option lines
         --  was reported as read by nobody, which is the check being wrong
         --  rather than the catalog.
         for Index in 1 .. Opt.Option_Count loop
            if Opt.Option_Help (Index) /= "" then
               for Kind in Opt.Command_Kind loop
                  if Kind /= Opt.Command_None
                    and then Opt.Option_Commands (Index) (Kind)
                  then
                     Reached ("help." & Opt.Command_Word (Kind) & "."
                              & Opt.Option_Help (Index));
                  end if;
               end loop;
            end if;
         end loop;

         --  A sixth: one help line per interactive command, built from the
         --  word the enumeration carries.
         for Kind in Model_Runner.CLI.Interactive.Command_Kind loop
            declare
               Word : constant String :=
                 Model_Runner.CLI.Interactive.Command_Word (Kind);
            begin
               if Word /= "" then
                  Reached ("cli.interactive.help."
                           & Word (Word'First + 1 .. Word'Last));
               end if;
            end;
         end loop;

         --  A fifth: the general help's line for each command, and each
         --  topic's usage and summary, built from the command word.
         for Kind in Opt.Command_Kind loop
            if Kind /= Opt.Command_None then
               Reached ("cli.general.command." & Opt.Command_Word (Kind));
               Reached ("help." & Opt.Command_Word (Kind) & ".usage");
               Reached ("help." & Opt.Command_Word (Kind) & ".summary");
               Reached ("help." & Opt.Command_Word (Kind) & ".options");
            end if;
         end loop;

         Scan_Keys ("src");

         for Index in 1 .. Count loop
            Result.Performed := Result.Performed + 1;
            if not Keys (Index).Read then
               Fail ("nothing reads the catalog key "
                     & Keys (Index).Text (1 .. Keys (Index).Last));
            end if;
         end loop;
      end;

      --  No test names a model file under fixtures by hand.
      --
      --  fixtures/*.gguf is ignored by git, deliberately: a model file is
      --  not committed unless its licence plainly allows it. Three tests
      --  then read fixtures/tiny-model.gguf as though the repository
      --  carried it, and it was carried by one machine -- the one where
      --  `tests fixtures` had been run -- so the suite passed here and
      --  failed on every clean checkout for forty consecutive pushes.
      --
      --  The rule that prevents the next one: a model under fixtures is
      --  named through Tiny_Model.Suite_Fixture, which is beside the
      --  operation that writes it, so a test that reads one cannot avoid
      --  writing it. A test needing a different model writes it into obj
      --  like every other fixture the suite builds for itself.
      declare
         Named : Natural := 0;

         procedure Visit_Fixture_Paths (Relative : String) is
            Text   : constant String := Contents (Relative);
            Needle : constant String := """fixtures/";
         begin
            --  The registry that carries the path is where the literal
            --  belongs, so it is the one file allowed to hold one.
            if T.Ends_With (Relative, "tiny_model.ads") then
               return;
            end if;

            if Text'Length < Needle'Length then
               return;
            end if;

            for Index in Text'First .. Text'Last - Needle'Length + 1 loop
               if Text (Index .. Index + Needle'Length - 1) = Needle then
                  declare
                     From : constant Natural := Index + Needle'Length;
                     Stop : Natural := From;
                  begin
                     while Stop <= Text'Last and then Text (Stop) /= '"' loop
                        Stop := Stop + 1;
                     end loop;

                     declare
                        Named_Path : constant String :=
                          Text (From .. Stop - 1);
                     begin
                        Named := Named + 1;
                        Result.Performed := Result.Performed + 1;
                        if T.Ends_With (Named_Path, ".gguf") then
                           Fail (Relative & " names fixtures/" & Named_Path
                                 & " by hand; git does not carry a model "
                                 & "file, so read it through "
                                 & "Tiny_Model.Suite_Fixture, which writes "
                                 & "it, or write your own into obj");
                        end if;
                     end;
                  end;
               end if;
            end loop;
         end Visit_Fixture_Paths;

         procedure Scan_Fixture_Paths is
           new For_Each_Source (Visit_Fixture_Paths);
      begin
         Scan_Fixture_Paths ("tests/src");

         --  The prompts and the expectation files are named this way and are
         --  committed, so finding none at all means this stopped reading the
         --  sources rather than that the sources stopped naming them.
         Result.Performed := Result.Performed + 1;
         if Named = 0 then
            Fail ("no fixture paths were found in the tests; the check no "
                  & "longer matches the sources it reads");
         end if;
      end;

      --  Every format the engine decodes has a fixture that carries it.
      --
      --  A format arrives with a decoder, a row in the support matrix, a row
      --  in the README and a name -- and all four of those are checked. What
      --  was not checked is whether anything can build a file that uses it,
      --  and without that there is no conformance sequence for it: the
      --  engine decodes it and nothing independent ever reads what it
      --  decoded. Nine of thirteen formats were in that state, and the only
      --  reason they are not still is that somebody wrote nine encoders.
      --
      --  The fixture names its formats as the engine names them, so this is
      --  a comparison of two enumerations rather than a table to keep.
      declare
         Missing : Natural := 0;
      begin
         for Format in Model_Runner.GGUF.Tensor_Type loop
            if Model_Runner.Quantization.Is_Decodable (Format) then
               declare
                  Wanted : constant String :=
                    T.To_Lower (Model_Runner.GGUF.Type_Name (Format));
                  Found  : Boolean := False;
               begin
                  for Built in Tiny_Model.Weight_Format loop
                     if T.To_Lower (Tiny_Model.Weight_Format'Image (Built))
                        = Wanted
                     then
                        Found := True;
                     end if;
                  end loop;

                  Result.Performed := Result.Performed + 1;
                  if not Found then
                     Missing := Missing + 1;
                     Fail ("the engine decodes "
                           & Model_Runner.GGUF.Type_Name (Format)
                           & " and the fixture cannot build one, so nothing "
                           & "independent reads what it decodes");
                  end if;
               end;
            end if;
         end loop;

         --  And nothing the fixture builds that the engine cannot read,
         --  which would be a sequence that proves nothing.
         for Built in Tiny_Model.Weight_Format loop
            declare
               Named : constant String :=
                 T.To_Lower (Tiny_Model.Weight_Format'Image (Built));
               Found : Boolean := False;
            begin
               for Format in Model_Runner.GGUF.Tensor_Type loop
                  if Model_Runner.Quantization.Is_Decodable (Format)
                    and then T.To_Lower
                               (Model_Runner.GGUF.Type_Name (Format)) = Named
                  then
                     Found := True;
                  end if;
               end loop;

               Result.Performed := Result.Performed + 1;
               if not Found then
                  Fail ("the fixture builds " & Named
                        & ", which the engine does not decode");
               end if;
            end;
         end loop;

         Result.Performed := Result.Performed + 1;
         if Missing > 0 then
            Fail (Natural'Image (Missing)
                  & " decodable formats have no fixture; conformance covers "
                  & "what the fixture can build and nothing else");
         end if;
      end;

      --  Every interactive command has a word, a help line, and a help
      --  line that names it -- in every locale.
      --
      --  The interactive command set was three lists: an enumeration, a
      --  chain matching seven words, and seven catalog keys written out in
      --  order, with nothing relating them. It was the only command
      --  enumeration in the program that answered to no check, so an eighth
      --  command would have compiled, parsed and dispatched without
      --  appearing in the one screen that lists them.
      --
      --  The words are written a fourth time inside the help text itself --
      --  "/stats          show the statistics of the last turn" -- once per
      --  locale. A renamed command would have left every translation
      --  advertising something the parser refuses, so the line must carry
      --  the word it documents.
      declare
         Catalog : constant String :=
           Contents ("resources/messages/catalog.txt");

         --  The value of a key in one locale, or an empty string.
         function Line_Of (Locale, Key : String) return String is
            Needle : constant String :=
              Character'Val (10) & Locale & "." & Key & " = ";
            From   : Natural := 0;
         begin
            if Catalog'Length < Needle'Length then
               return "";
            end if;
            for Index in Catalog'First
                         .. Catalog'Last - Needle'Length + 1
            loop
               if Catalog (Index .. Index + Needle'Length - 1) = Needle then
                  From := Index + Needle'Length;
                  exit;
               end if;
            end loop;
            if From = 0 then
               return "";
            end if;
            for Index in From .. Catalog'Last loop
               if Catalog (Index) = Character'Val (10) then
                  return Catalog (From .. Index - 1);
               end if;
            end loop;
            return Catalog (From .. Catalog'Last);
         end Line_Of;
      begin
         for Kind in Model_Runner.CLI.Interactive.Command_Kind loop
            declare
               Word : constant String :=
                 Model_Runner.CLI.Interactive.Command_Word (Kind);
            begin
               if Word /= "" then
                  Result.Performed := Result.Performed + 1;
                  if Word (Word'First) /= '/' then
                     Fail ("the interactive command " & Word
                           & " does not begin with a slash");
                  end if;

                  --  Round-tripped through the parser, so the word the
                  --  enumeration carries is the word that is answered.
                  Result.Performed := Result.Performed + 1;
                  if Model_Runner.CLI.Interactive.Parse (Word).Kind /= Kind
                  then
                     Fail ("the interactive command " & Word
                           & " is not parsed as itself");
                  end if;

                  declare
                     Key : constant String :=
                       "cli.interactive.help."
                       & Word (Word'First + 1 .. Word'Last);
                  begin
                     for Locale in 1 .. 3 loop
                        declare
                           Name : constant String :=
                             (case Locale is
                                when 1 => "en",
                                when 2 => "da",
                                when others => "qps");
                           Shown : constant String := Line_Of (Name, Key);
                        begin
                           --  Danish carries a subset and inherits the
                           --  rest, so a line it does not have is not
                           --  missing. English and the pseudo-locale carry
                           --  everything.
                           Result.Performed := Result.Performed + 1;
                           if Shown = "" then
                              if Name /= "da" then
                                 Fail ("the interactive command " & Word
                                       & " has no help line in " & Name);
                              end if;
                           elsif not Holds (Shown, Word) then
                              Fail ("the " & Name & " help line for " & Word
                                    & " does not name it: " & Shown);
                           end if;
                        end;
                     end loop;
                  end;
               end if;
            end;
         end loop;

         --  And a word no command has is answered as unknown rather than
         --  mistaken for one.
         Result.Performed := Result.Performed + 1;
         if Model_Runner.CLI.Interactive.Parse ("/nonsense").Kind
            /= Model_Runner.CLI.Interactive.Unknown
         then
            Fail ("an interactive command nobody has was recognized");
         end if;
      end;

      --  Every command has a help topic, and every topic is a command.
      --
      --  `help nonsense` printed the general help and exited successfully,
      --  so a mistyped topic was answered with a screen the reader had not
      --  asked for, while the same word typed as a command was refused by
      --  name. Behind that were two lists: a chain naming four topics, and
      --  a Command_Kind naming exactly those four, with nothing relating
      --  them -- a fifth command would have compiled, dispatched, taken
      --  options and had no help at all.
      declare
         Catalog : constant String :=
           Contents ("resources/messages/catalog.txt");

         function Documented (Key : String) return Boolean
         is (Holds (Catalog, Character'Val (10) & "en." & Key & " ="));
      begin
         for Kind in Opt.Command_Kind loop
            if Kind /= Opt.Command_None then
               declare
                  Word : constant String := Opt.Command_Word (Kind);
               begin
                  --  A word to type, and the two lines every topic shows.
                  Result.Performed := Result.Performed + 1;
                  if Word = "" then
                     Fail ("a command has no word to type: "
                           & Opt.Command_Kind'Image (Kind));
                  end if;

                  Result.Performed := Result.Performed + 1;
                  if not Documented ("help." & Word & ".usage") then
                     Fail ("the " & Word
                           & " command has no help.usage line");
                  end if;

                  Result.Performed := Result.Performed + 1;
                  if not Documented ("help." & Word & ".summary") then
                     Fail ("the " & Word
                           & " command has no help.summary line");
                  end if;

                  --  And a line in the list of commands the general help
                  --  prints, which is built from this same enumeration.
                  Result.Performed := Result.Performed + 1;
                  if not Documented ("cli.general.command." & Word) then
                     Fail ("the " & Word
                           & " command is missing from the general help");
                  end if;

                  --  The word round-trips, so a topic names its command.
                  Result.Performed := Result.Performed + 1;
                  if Opt.Command_Of (Word) /= Kind then
                     Fail ("the word " & Word & " does not name "
                           & Opt.Command_Kind'Image (Kind));
                  end if;
               end;
            end if;
         end loop;

         --  A word no command has is no topic either.
         Result.Performed := Result.Performed + 1;
         if Opt.Command_Of ("nonsense") /= Opt.Command_None then
            Fail ("a word no command has was read as a command");
         end if;
      end;

      --  The program answers for its own options.
      --
      --  Three answers to one question used to be given separately: what
      --  the parser accepts, what a command may be given, and what the help
      --  screens list. Every option reached every command -- `inspect
      --  m.gguf --temperature 0.5 --interactive` ran the inspection and said
      --  nothing -- and the help lists were written out beside the parser,
      --  so inspect documented five options and took thirty-seven, with
      --  --quiet and --verbose working there while appearing only under run.
      declare
         Parser  : constant String :=
           Contents ("src/library/model_runner-cli-options.adb");
         Catalog : constant String :=
           Contents ("resources/messages/catalog.txt");
         Found   : Natural := 0;

         --  The catalog carries an English entry for this key.
         function Documented (Key : String) return Boolean
         is (Holds (Catalog, Character'Val (10) & "en." & Key & " ="));
      begin
         Result.Performed := Result.Performed + 1;
         if Parser'Length = 0 then
            Fail ("the option parser is missing; the option check no longer "
                  & "reads the code it describes");
         end if;

         for Index in 1 .. Opt.Option_Count loop
            declare
               Name : constant String := Opt.Option_Name (Index);
               Help : constant String := Opt.Option_Help (Index);
            begin
               --  The parser reads what the registry lists.
               Result.Performed := Result.Performed + 1;
               if not Holds (Parser, "Name = """ & Name & """") then
                  Fail ("the option registry lists " & Name
                        & ", which the parser does not read");
               end if;

               --  And every command that takes it documents it, in a line
               --  of its own, so that a screen cannot say less than the
               --  command accepts.
               if Help /= "" then
                  for Kind in Opt.Command_Kind loop
                     if Opt.Option_Commands (Index) (Kind)
                       and then Kind in Opt.Command_Run | Opt.Command_Inspect
                     then
                        declare
                           Topic : constant String :=
                             (if Kind = Opt.Command_Run
                              then "run" else "inspect");
                        begin
                           Result.Performed := Result.Performed + 1;
                           if not Documented
                                    ("help." & Topic & "." & Help)
                           then
                              Fail (Topic & " takes " & Name
                                    & ", which no help line documents");
                           end if;
                        end;
                     end if;
                  end loop;
               end if;
            end;
         end loop;

         --  And back the other way, from the parser to the registry.
         declare
            Needle : constant String := "Name = ""--";
            Index  : Natural := Parser'First;
         begin
            while Index <= Parser'Last - Needle'Length loop
               if Parser (Index .. Index + Needle'Length - 1) = Needle then
                  declare
                     From : constant Natural := Index + Needle'Length - 2;
                     Stop : Natural := From;
                     Seen : Boolean := False;
                  begin
                     while Stop <= Parser'Last
                       and then Parser (Stop) /= '"'
                     loop
                        Stop := Stop + 1;
                     end loop;

                     declare
                        Name : constant String := Parser (From .. Stop - 1);
                     begin
                        Found := Found + 1;
                        for Which in 1 .. Opt.Option_Count loop
                           if Opt.Option_Name (Which) = Name then
                              Seen := True;
                           end if;
                        end loop;

                        Result.Performed := Result.Performed + 1;
                        if not Seen then
                           Fail ("the parser reads " & Name
                                 & ", which the option registry does not "
                                 & "list");
                        end if;
                     end;
                  end;
               end if;
               Index := Index + 1;
            end loop;
         end;

         Result.Performed := Result.Performed + 1;
         if Found /= Opt.Option_Count then
            Fail ("the parser reads" & Natural'Image (Found)
                  & " options and the registry lists"
                  & Natural'Image (Opt.Option_Count));
         end if;
      end;

      --  The tests tool answers for its own commands.
      --
      --  Every registry in this repository is asked of the code, and the
      --  crate that does the asking could not say what its own commands
      --  were. There were two hand-kept lists: the usage line named six of
      --  eleven, so mistyping a command told you about half the tool, and
      --  the README's tooling row named a different seven -- missing the
      --  command a section of that same file tells readers to run, added
      --  the day before. Both sat beside a dispatch chain neither could see.
      declare
         Tool   : constant String := Contents ("tests/src/tests_main.adb");
         Readme : constant String := Contents ("README.md");

         --  Every command the dispatch answers, as a literal it compares
         --  against. A command answered by nothing is a line in a list.
         Found : Natural := 0;
      begin
         Result.Performed := Result.Performed + 1;
         if Tool'Length = 0 then
            Fail ("tests/src/tests_main.adb is missing; the command check no "
                  & "longer reads the tool it describes");
         end if;

         for Index in 1 .. Tool_Commands.Count loop
            declare
               Name : constant String := Tool_Commands.Item (Index).Name.all;
            begin
               Result.Performed := Result.Performed + 1;
               if not Holds (Tool, "Command = """ & Name & """") then
                  Fail ("Tool_Commands lists " & Name
                        & ", which the tool does not dispatch");
               end if;

               Result.Performed := Result.Performed + 1;
               if not Holds (Readme, "`tests " & Name & "`") then
                  Fail ("the tests tool answers " & Name
                        & ", which the README does not name");
               end if;
            end;
         end loop;

         --  And the other way, from the dispatch chain back to the list.
         declare
            Needle : constant String := "Command = """;
            Index  : Natural := Tool'First;
         begin
            while Index <= Tool'Last - Needle'Length loop
               if Tool (Index .. Index + Needle'Length - 1) = Needle then
                  declare
                     From : constant Natural := Index + Needle'Length;
                     Stop : Natural := From;
                     Seen : Boolean := False;
                  begin
                     while Stop <= Tool'Last and then Tool (Stop) /= '"' loop
                        Stop := Stop + 1;
                     end loop;

                     declare
                        Name : constant String := Tool (From .. Stop - 1);
                     begin
                        Found := Found + 1;
                        for Which in 1 .. Tool_Commands.Count loop
                           if Tool_Commands.Item (Which).Name.all = Name then
                              Seen := True;
                           end if;
                        end loop;

                        Result.Performed := Result.Performed + 1;
                        if not Seen then
                           Fail ("the tool dispatches " & Name
                                 & ", which Tool_Commands does not list");
                        end if;
                     end;
                  end;
               end if;
               Index := Index + 1;
            end loop;
         end;

         --  The two things a reader is told about a command must agree: the
         --  usage line says what it takes and the tool refuses what is not
         --  in the option list, and those were separate strings written by
         --  hand a day apart. Every option named in one must be in the
         --  other.
         for Index in 1 .. Tool_Commands.Count loop
            declare
               Entry_Value : constant Tool_Commands.Command :=
                 Tool_Commands.Item (Index);
               Shown : constant String := Entry_Value.Takes.all;
               Taken : constant String := Entry_Value.Options.all;
               From  : Natural := Shown'First;
            begin
               --  Every --option in the usage text is one the tool accepts.
               while From <= Shown'Last - 2 loop
                  if Shown (From .. From + 1) = "--" then
                     declare
                        Stop : Natural := From + 2;
                     begin
                        while Stop <= Shown'Last
                          and then Shown (Stop) not in ' ' | '=' | ']'
                        loop
                           Stop := Stop + 1;
                        end loop;

                        declare
                           Named : constant String :=
                             Shown (From .. Stop - 1);
                        begin
                           Result.Performed := Result.Performed + 1;
                           if not Holds (Taken, " " & Named & " ") then
                              Fail ("the usage line for "
                                    & Entry_Value.Name.all & " shows "
                                    & Named
                                    & ", which it does not accept");
                           end if;
                        end;
                        From := Stop;
                     end;
                  else
                     From := From + 1;
                  end if;
               end loop;

               --  And every option it accepts is shown.
               declare
                  Start : Natural := Taken'First;
               begin
                  while Start <= Taken'Last - 2 loop
                     if Taken (Start .. Start + 1) = "--" then
                        declare
                           Stop : Natural := Start + 2;
                        begin
                           while Stop <= Taken'Last
                             and then Taken (Stop) /= ' '
                           loop
                              Stop := Stop + 1;
                           end loop;

                           declare
                              Named : constant String :=
                                Taken (Start .. Stop - 1);
                           begin
                              Result.Performed := Result.Performed + 1;
                              if not Holds (Shown, Named) then
                                 Fail (Entry_Value.Name.all & " accepts "
                                       & Named
                                       & ", which its usage line does not "
                                       & "show");
                              end if;
                           end;
                           Start := Stop;
                        end;
                     else
                        Start := Start + 1;
                     end if;
                  end loop;
               end;
            end;
         end loop;

         Result.Performed := Result.Performed + 1;
         if Found /= Tool_Commands.Count then
            Fail ("the tool dispatches" & Natural'Image (Found)
                  & " commands and Tool_Commands lists"
                  & Natural'Image (Tool_Commands.Count));
         end if;
      end;

      --  Every public operation has a reader in the program, not only in
      --  the tests.
      --
      --  There has been a check that every public operation has a reader
      --  since the registries were first asked of the code, and the tests
      --  counted as readers. So an operation the program never calls passed
      --  it, and about thirty did: the check read as though the surface were
      --  in use. An operation only its own tests call is not tested code, it
      --  is a test fixture with a public name.
      --
      --  A reader is a mention that is not a declaration, a body header, an
      --  end line or a comment. Where a name is common enough to be somebody
      --  else's too -- Open, Close, Text -- that overcounts, which fails
      --  towards saying an operation is used. This check is for the ones
      --  nothing uses at all.
      declare
         --  Raised from four hundred when the count reached it. That it
         --  reached it was found the hard way: the collector stopped taking
         --  names and the check then reported that an operation declared in
         --  plain sight was declared nowhere. A bound that is silently full
         --  makes a check weaker as a project grows, which is the opposite
         --  of what a check is for, so overflowing it is now a failure that
         --  names itself.
         Room  : constant := 800;
         Width : constant := 64;
         Named : constant := 64;

         Overflowed : Boolean := False;

         type Operation is record
            Name : String (1 .. Width) := [others => ' '];
            Last : Natural := 0;
            File : String (1 .. Named) := [others => ' '];
            Kept : Natural := 0;
            Read : Boolean := False;
         end record;

         Held  : array (1 .. Room) of Operation;
         Count : Natural := 0;

         --  Report whether a line declares, defines or ends a subprogram, or
         --  is a comment. Those mention a name without reading it.
         function Is_Definition (Line : String) return Boolean is
            From : Natural := Line'First;
         begin
            while From <= Line'Last and then Line (From) = ' ' loop
               From := From + 1;
            end loop;
            if From > Line'Last then
               return True;
            end if;
            declare
               Rest : constant String := Line (From .. Line'Last);

               function Opens (Word : String) return Boolean
               is (Rest'Length >= Word'Length
                   and then Rest (Rest'First .. Rest'First + Word'Length - 1)
                            = Word);
            begin
               return Opens ("function ") or else Opens ("procedure ")
                 or else Opens ("end ") or else Opens ("--")
                 or else Opens ("overriding");
            end;
         end Is_Definition;

         --  Collect the public operations a spec declares.
         procedure Visit_Spec (Relative : String) is
            Text   : constant String := Contents (Relative);
            Cursor : Natural := Text'First;
            Hidden : Boolean := False;
         begin
            if Relative'Length < 4
              or else Relative (Relative'Last - 3 .. Relative'Last) /= ".ads"
            then
               return;
            end if;

            while Cursor <= Text'Last loop
               declare
                  Stop : Natural := Cursor;
               begin
                  while Stop <= Text'Last
                    and then Text (Stop) /= Character'Val (10)
                  loop
                     Stop := Stop + 1;
                  end loop;

                  declare
                     Line : constant String := Text (Cursor .. Stop - 1);
                  begin
                     if Line = "private" then
                        Hidden := True;
                     end if;

                     --  Three spaces exactly: an operation of this package
                     --  rather than one nested inside another declaration.
                     if not Hidden
                       and then Line'Length > 14
                       and then Line (Line'First .. Line'First + 2) = "   "
                       and then Line (Line'First + 3) /= ' '
                       and then (Line (Line'First + 3 .. Line'First + 11)
                                   = "function "
                                 or else Line (Line'First + 3
                                               .. Line'First + 12)
                                           = "procedure ")
                     then
                        declare
                           From : constant Natural :=
                             (if Line (Line'First + 3) = 'f'
                              then Line'First + 12 else Line'First + 13);
                           To   : Natural := From;
                        begin
                           while To <= Line'Last
                             and then Line (To) in 'A' .. 'Z' | 'a' .. 'z'
                                                 | '0' .. '9' | '_'
                           loop
                              To := To + 1;
                           end loop;

                           if To > From
                             and then Count >= Room
                             and then To - From <= Width
                           then
                              Overflowed := True;
                           end if;

                           if To > From
                             and then Count < Room
                             and then To - From <= Width
                           then
                              declare
                                 Size : constant Natural :=
                                   Natural'Min (Named, Relative'Length);
                              begin
                                 Count := Count + 1;
                                 Held (Count).Last := To - From;
                                 Held (Count).Name (1 .. To - From) :=
                                   Line (From .. To - 1);
                                 Held (Count).Kept := Size;
                                 Held (Count).File (1 .. Size) :=
                                   Relative (Relative'First
                                             .. Relative'First + Size - 1);
                              end;
                           end if;
                        end;
                     end if;
                  end;

                  Cursor := Stop + 1;
               end;
            end loop;
         end Visit_Spec;

         --  Mark every operation a production source reads.
         procedure Visit_Readers (Relative : String) is
            Text   : constant String := Contents (Relative);
            Cursor : Natural := Text'First;
         begin
            while Cursor <= Text'Last loop
               declare
                  Stop : Natural := Cursor;
               begin
                  while Stop <= Text'Last
                    and then Text (Stop) /= Character'Val (10)
                  loop
                     Stop := Stop + 1;
                  end loop;

                  declare
                     Line : constant String := Text (Cursor .. Stop - 1);
                  begin
                     if not Is_Definition (Line) then
                        for Index in 1 .. Count loop
                           if not Held (Index).Read
                             and then Holds
                                        (Line,
                                         Held (Index).Name
                                           (1 .. Held (Index).Last))
                           then
                              Held (Index).Read := True;
                           end if;
                        end loop;
                     end if;
                  end;

                  Cursor := Stop + 1;
               end;
            end loop;
         end Visit_Readers;

         procedure Collect is new For_Each_Source (Visit_Spec);
         procedure Read_Them is new For_Each_Source (Visit_Readers);
      begin
         Collect ("src");
         Read_Them ("src");

         Result.Performed := Result.Performed + 1;
         if Count < 200 then
            Fail ("only" & Natural'Image (Count) & " public operations were "
                  & "found; the check no longer matches the specs it reads");
         end if;

         Result.Performed := Result.Performed + 1;
         if Overflowed then
            Fail ("more than" & Natural'Image (Room) & " public operations "
                  & "were found and the rest were not checked; raise the "
                  & "bound in this check");
         end if;

         for Index in 1 .. Count loop
            Result.Performed := Result.Performed + 1;
            if not Held (Index).Read
              and then not Library_Surface.Is_Listed
                             (Held (Index).Name (1 .. Held (Index).Last))
            then
               Fail (Held (Index).File (1 .. Held (Index).Kept) & " declares "
                     & Held (Index).Name (1 .. Held (Index).Last)
                     & ", which nothing in the program calls and which "
                     & "Library_Surface does not list");
            end if;
         end loop;

         --  And the list cannot outlive what it describes. An operation that
         --  starts being called, or that is renamed or removed, has to come
         --  off it -- otherwise the list would drift into the same
         --  unexamined state it was written to end.
         for Index in 1 .. Library_Surface.Count loop
            declare
               Name  : constant String := Library_Surface.Item (Index);
               Found : Boolean := False;
            begin
               Result.Performed := Result.Performed + 1;
               for Which in 1 .. Count loop
                  if Held (Which).Name (1 .. Held (Which).Last) = Name then
                     Found := True;
                     if Held (Which).Read then
                        Fail ("Library_Surface lists " & Name
                              & ", which the program now calls");
                     end if;
                  end if;
               end loop;

               if not Found then
                  Fail ("Library_Surface lists " & Name
                        & ", which no public spec declares");
               end if;
            end;
         end loop;
      end;

      --  The catalog parses, in every locale it carries.
      --
      --  Everything else here reads the catalog as text: keys, readers,
      --  counts, help lines. None of that notices a catalog the message
      --  runtime refuses, and refusing is total -- one bad line and every
      --  locale stops loading, the program renders identifiers in angle
      --  brackets, and nothing says why. Naming a placeholder {command}
      --  did exactly that, and the fault surfaced as four unrelated locale
      --  tests reporting that a catalog did not load, which is a long way
      --  from the line that caused it.
      --
      --  The locales are taken from the file rather than listed, so one
      --  added is one checked.
      declare
         Text_Body : constant String :=
           Contents ("resources/messages/catalog.txt");

         Room  : constant := 16;
         Width : constant := 16;

         type Locale_Name is record
            Text : String (1 .. Width) := [others => ' '];
            Last : Natural := 0;
         end record;

         Names : array (1 .. Room) of Locale_Name;
         Count : Natural := 0;

         --  Remember a locale prefix once.
         procedure Note (Name : String) is
         begin
            if Name'Length = 0 or else Name'Length > Width then
               return;
            end if;
            for Index in 1 .. Count loop
               if Names (Index).Text (1 .. Names (Index).Last) = Name then
                  return;
               end if;
            end loop;
            if Count < Room then
               Count := Count + 1;
               Names (Count).Last := Name'Length;
               Names (Count).Text (1 .. Name'Length) := Name;
            end if;
         end Note;

         Cursor : Natural := Text_Body'First;
      begin
         while Cursor <= Text_Body'Last loop
            declare
               Stop : Natural := Cursor;
            begin
               while Stop <= Text_Body'Last
                 and then Text_Body (Stop) /= Character'Val (10)
               loop
                  Stop := Stop + 1;
               end loop;

               declare
                  Line : constant String := Text_Body (Cursor .. Stop - 1);
               begin
                  for Index in Line'Range loop
                     exit when Line (Index) = ' ' or else Line (Index) = '=';
                     if Line (Index) = '.' then
                        Note (Line (Line'First .. Index - 1));
                        exit;
                     end if;
                  end loop;
               end;

               Cursor := Stop + 1;
            end;
         end loop;

         Result.Performed := Result.Performed + 1;
         if Count = 0 then
            Fail ("no locales were found in the catalog; the check no longer "
                  & "matches the file it reads");
         end if;

         for Index in 1 .. Count loop
            declare
               Name : constant String :=
                 Names (Index).Text (1 .. Names (Index).Last);
               Held : Model_Runner.Localization.Catalog;
            begin
               --  The catalog under the root this run was given, not the
               --  one beside the executable. Every other check here reads
               --  the file through Contents, which is root-relative, and
               --  this opened Platform.Catalog_Path, which is relative to
               --  the program. Pointed at another tree it answered about
               --  this one -- a check that reports on a file nobody asked
               --  it about is worse than no check, because it reports
               --  green.
               Model_Runner.Localization.Open
                 (Held, Path ("resources/messages/catalog.txt"), Name);

               Result.Performed := Result.Performed + 1;
               if not Model_Runner.Localization.Is_Ready (Held) then
                  declare
                     Guilty : constant String :=
                       Offending_Line
                         (Path ("resources/messages/catalog.txt"),
                          Path ("obj/catalog-candidate.txt"));
                  begin
                     pragma Assert (True);
                     Fail ("the message catalog does not parse in " & Name
                           & "; the runtime refuses it whole, so nothing "
                           & "renders in any locale"
                           & (if Guilty = "" then ""
                              else " -- the line is: " & Guilty));
                  end;
               else
                  --  And it renders rather than reaching the emergency
                  --  form, which is what a caller would see instead.
                  declare
                     Shown : constant String :=
                       Model_Runner.Localization.Text
                         (Held, "application.name");
                  begin
                     Result.Performed := Result.Performed + 1;
                     if Shown'Length = 0
                       or else Shown (Shown'First) = '<'
                     then
                        Fail ("the catalog loaded in " & Name
                              & " but rendered the emergency form");
                     end if;
                  end;
               end if;

               Model_Runner.Localization.Close (Held);
            end;
         end loop;
      end;

      --  And the other way: every message key the code names is in the
      --  catalog.
      --
      --  The check above walks the catalog and asks what reads each key. It
      --  cannot see a key the code names that the catalog does not have, and
      --  that failure ships: the emergency form renders the identifier in
      --  angle brackets, so a mistyped label prints
      --  <cli.inspect.label.wrkers> where a word should be, in every locale
      --  at once. Nothing failed when that was tried.
      --
      --  The keys are taken from the calls that consume them rather than
      --  from every string in the sources, because a GGUF metadata key looks
      --  exactly like a message key and is not one. A key built by
      --  concatenation ends at a dot and is left to the families above.
      declare
         Catalog : constant String :=
           Contents ("resources/messages/catalog.txt");

         Seen : Natural := 0;

         --  Report whether the catalog carries an English entry.
         function Has_Entry (Key : String) return Boolean
         is (Holds (Catalog, Character'Val (10) & "en." & Key & " ="));

         --  Report whether a name at this position is a whole word.
         function Standalone
           (Text : String; From, To : Natural) return Boolean
         is ((From = Text'First
              or else (Text (From - 1) not in 'A' .. 'Z' | 'a' .. 'z'
                                            | '0' .. '9' | '_'))
             and then (To = Text'Last
                       or else (Text (To + 1) not in 'A' .. 'Z' | 'a' .. 'z'
                                                   | '0' .. '9' | '_')));

         --  Report whether this position sits inside a comment.
         function In_Comment (Text : String; At_Index : Natural) return Boolean
         is
            Index : Natural := At_Index;
         begin
            while Index > Text'First loop
               exit when Text (Index - 1) = Character'Val (10);
               if Index - 1 > Text'First
                 and then Text (Index - 2 .. Index - 1) = "--"
               then
                  return True;
               end if;
               Index := Index - 1;
            end loop;
            return False;
         end In_Comment;

         --  Check every call of one operation in one source.
         procedure Scan_Calls (Text, Name, Relative : String) is
            Index : Natural := Text'First;
         begin
            if Text'Length <= Name'Length then
               return;
            end if;
            while Index <= Text'Last - Name'Length + 1 loop
               if Text (Index .. Index + Name'Length - 1) = Name
                 and then Standalone (Text, Index, Index + Name'Length - 1)
                 and then not In_Comment (Text, Index)
               then
                  --  The first two arguments, and only what sits directly
                  --  in them. A key is the first argument or the one after
                  --  the console; a literal nested inside a call at that
                  --  position is somebody else's argument -- the name of a
                  --  placeholder, most often -- and not a key at all.
                  declare
                     Stop   : Natural := Index + Name'Length;
                     Depth  : Natural := 0;
                     Commas : Natural := 0;
                     First  : Natural := 0;
                     Last   : Natural := 0;
                  begin
                     while Stop <= Text'Last
                       and then Text (Stop) /= ';'
                       and then Stop - Index < 400
                     loop
                        case Text (Stop) is
                           when '(' =>
                              Depth := Depth + 1;
                           when ')' =>
                              exit when Depth <= 1;
                              Depth := Depth - 1;
                           when ',' =>
                              if Depth = 1 then
                                 Commas := Commas + 1;
                                 exit when Commas >= 2;
                              end if;
                           when '"' =>
                              if Depth = 1 then
                                 First := Stop + 1;
                                 Last := First;
                                 while Last <= Text'Last
                                   and then Text (Last) /= '"'
                                 loop
                                    Last := Last + 1;
                                 end loop;
                                 exit;
                              end if;
                           when others =>
                              null;
                        end case;
                        Stop := Stop + 1;
                     end loop;

                     if First > 0 and then Last > First then
                        declare
                           Key : constant String := Text (First .. Last - 1);
                        begin
                           --  A key assembled from an enumeration ends at the
                           --  dot; those are answered by the families above.
                           if Key (Key'Last) /= '.' then
                              Seen := Seen + 1;
                              Result.Performed := Result.Performed + 1;
                              if not Has_Entry (Key) then
                                 Fail (Relative & " names the message key "
                                       & Key & ", which the catalog does not "
                                       & "have");
                              end if;
                           end if;
                        end;
                     end if;
                  end;
               end if;
               Index := Index + 1;
            end loop;
         end Scan_Calls;

         --  The operations whose first string argument is a message key.
         procedure Visit_Calls (Relative : String) is
            Text : constant String := Contents (Relative);
         begin
            Scan_Calls (Text, "Put_Message", Relative);
            Scan_Calls (Text, "Message_Value", Relative);
            Scan_Calls (Text, "Put_Heading", Relative);
            Scan_Calls (Text, "Put_Field", Relative);
            Scan_Calls (Text, "Put_Note", Relative);
            Scan_Calls (Text, "Put_Prompt", Relative);
            Scan_Calls (Text, "Put_Option", Relative);
            Scan_Calls (Text, "Warn", Relative);
         end Visit_Calls;

         procedure Scan_Sources is new For_Each_Source (Visit_Calls);
      begin
         Scan_Sources ("src");

         Result.Performed := Result.Performed + 1;
         if Seen < 50 then
            Fail ("only" & Natural'Image (Seen) & " message keys were found "
                  & "in the sources; the check no longer matches the calls "
                  & "it reads");
         end if;
      end;

      --  Documentation registries agree with the code.
      declare
         Matrix : constant String := Contents ("docs/support-matrix.md");
      begin
         Result.Performed := Result.Performed + 1;
         if Matrix'Length = 0 then
            Fail ("docs/support-matrix.md is missing");
         end if;
      end;

      --  Every format the engine decodes is named where a reader looks.
      --
      --  The README's quantization row listed seven formats for as long as
      --  thirteen were implemented, and the support matrix said the multiply
      --  was folded into the decode for Q4_0 after that had been measured
      --  1.79 times slower and taken out. Both are tables a reader consults
      --  to find out whether their file will open, and both had drifted.
      --
      --  Asked of the code rather than of a list kept beside it: a format
      --  added to Is_Decodable and not to the documents fails here.
      declare
         Matrix : constant String := Contents ("docs/support-matrix.md");
         Readme : constant String := Contents ("README.md");

         --  Whether Text holds Token with nothing alphanumeric on either
         --  side. A plain search would find F16 inside BF16 and report a
         --  format as documented because a longer one was.
         function Holds_Word (Text, Token : String) return Boolean is
            function Part_Of_A_Word (Letter : Character) return Boolean
            is (Letter in 'A' .. 'Z' or else Letter in 'a' .. 'z'
                or else Letter in '0' .. '9' or else Letter = '_');
         begin
            if Text'Length < Token'Length then
               return False;
            end if;
            for Index in Text'First .. Text'Last - Token'Length + 1 loop
               if Text (Index .. Index + Token'Length - 1) = Token
                 and then (Index = Text'First
                           or else not Part_Of_A_Word (Text (Index - 1)))
                 and then (Index + Token'Length > Text'Last
                           or else not Part_Of_A_Word
                                        (Text (Index + Token'Length)))
               then
                  return True;
               end if;
            end loop;
            return False;
         end Holds_Word;
         --  The one line of a table, from its leading bar to the end of the
         --  line. The README names formats in several places, so searching
         --  the whole file would have found every one of the six the
         --  quantization row was missing somewhere else and passed.
         function Row (Text, Opening : String) return String is
         begin
            if Text'Length < Opening'Length then
               return "";
            end if;
            for Index in Text'First .. Text'Last - Opening'Length + 1 loop
               if Text (Index .. Index + Opening'Length - 1) = Opening then
                  declare
                     Stop : Natural := Index;
                  begin
                     while Stop <= Text'Last
                       and then Text (Stop) /= Character'Val (10)
                     loop
                        Stop := Stop + 1;
                     end loop;
                     return Text (Index .. Stop - 1);
                  end;
               end if;
            end loop;
            return "";
         end Row;

         Listed : constant String := Row (Readme, "| Quantization |");

         function Architecture_Table return String
         is (Section (Matrix, "## Architecture"));

         Architectures : constant String := Architecture_Table;

         function Backend_Table return String
         is (Section (Matrix, "## Backend"));

         Backends : constant String := Backend_Table;
      begin
         Result.Performed := Result.Performed + 1;
         if Listed = "" then
            Fail ("README.md has no quantization row; the check no longer "
                  & "matches the document it reads");
         end if;

         --  Nothing this build has is listed among the things it has not.
         --
         --  Every positive claim in these documents is checked against the
         --  code. The list of absences was checked by nothing, and it said a
         --  second backend was absent for two commits after the second
         --  backend arrived -- in the section whose whole purpose is to say
         --  what the program does not do, which is the most misleading place
         --  for it and the least likely to be doubted.
         --
         --  What can be checked mechanically is narrow: a name the code has
         --  must not appear in that section. It cannot tell whether the prose
         --  around a name is still true, so the names are the part that is
         --  held.
         declare
            Absences : constant String := Section (Readme, "## Not implemented");
         begin
            Result.Performed := Result.Performed + 1;
            if Absences = "" then
               Fail ("README.md has no list of what is absent; the check no "
                     & "longer matches the document it reads");
            end if;

            for Kind in Model_Runner.Backend.Backend_Kind loop
               Result.Performed := Result.Performed + 1;
               if Holds_Word (Absences,
                              Model_Runner.Backend.Backend_Name (Kind))
               then
                  Fail ("the " & Model_Runner.Backend.Backend_Name (Kind)
                        & " backend is listed among the things this build "
                        & "does not have");
               end if;
            end loop;

            for Kind in Model_Runner.Llama.Architecture loop
               Result.Performed := Result.Performed + 1;
               if Holds_Word (Absences,
                              Model_Runner.Llama.Architecture_Name (Kind))
               then
                  Fail ("the " & Model_Runner.Llama.Architecture_Name (Kind)
                        & " architecture is listed among the things this "
                        & "build does not read");
               end if;
            end loop;

            for Format in Model_Runner.GGUF.Tensor_Type loop
               if Model_Runner.Quantization.Is_Decodable (Format) then
                  Result.Performed := Result.Performed + 1;
                  if Holds_Word (Absences,
                                 Model_Runner.GGUF.Type_Name (Format))
                  then
                     Fail ("the " & Model_Runner.GGUF.Type_Name (Format)
                           & " format is listed among the things this build "
                           & "cannot decode");
                  end if;
               end if;
            end loop;
         end;

         --  Every backend this build has has a row of its own in the
         --  matrix's backend table, and is named in the README's row.
         --
         --  The backends were checked in the help line and on the version
         --  screen, which is where they are listed, and not in the tables
         --  that describe what they do. So the section describing them went
         --  on describing one: worker pools and partitions and bounded
         --  queues, flat, as though the reference backend had any of them.
         for Kind in Model_Runner.Backend.Backend_Kind loop
            declare
               Name : constant String :=
                 Model_Runner.Backend.Backend_Name (Kind);
            begin
               Result.Performed := Result.Performed + 1;
               if not Holds (Backends,
                             Character'Val (10) & "| `" & Name & "` |")
               then
                  Fail ("this build has the " & Name
                        & " backend but the backend table in "
                        & "docs/support-matrix.md has no row for it");
               end if;

               Result.Performed := Result.Performed + 1;
               if not Holds_Word (Row (Readme, "| Backends |"), Name) then
                  Fail ("this build has the " & Name
                        & " backend but the README's backend row does not "
                        & "name it");
               end if;
            end;
         end loop;

         Result.Performed := Result.Performed + 1;
         if Backends = "" then
            Fail ("docs/support-matrix.md has no backend section; the check "
                  & "no longer matches the document it reads");
         end if;

         Result.Performed := Result.Performed + 1;
         if Row (Readme, "| Backends |") = "" then
            Fail ("README.md has no backend row; the check no longer "
                  & "matches the document it reads");
         end if;

         --  Every architecture this build reads is named where a reader
         --  looks. It is the registry added most recently and the only one
         --  that had no check, which is how the other four came to be wrong.
         for Kind in Model_Runner.Llama.Architecture loop
            declare
               Name : constant String :=
                 Model_Runner.Llama.Architecture_Name (Kind);
            begin
               --  In the architecture section, not anywhere. Qwen2 is
               --  also the name of a tokenizer cutting rule and has a row
               --  of its own in that table, which satisfied both a search
               --  of the whole file for the word and a search for a row
               --  carrying it.
               Result.Performed := Result.Performed + 1;
               if not Holds (Architectures,
                             Character'Val (10) & "| `" & Name & "` |")
               then
                  Fail ("this build reads " & Name
                        & " but the architecture table in "
                        & "docs/support-matrix.md has no row for it");
               end if;

               Result.Performed := Result.Performed + 1;
               if not Holds_Word (Row (Readme, "| Architecture profile |"),
                                  Name)
               then
                  Fail ("this build reads " & Name
                        & " but the README's architecture row does not name "
                        & "it");
               end if;
            end;
         end loop;

         Result.Performed := Result.Performed + 1;
         if Architectures = "" then
            Fail ("docs/support-matrix.md has no architecture section; the "
                  & "check no longer matches the document it reads");
         end if;

         Result.Performed := Result.Performed + 1;
         if Row (Readme, "| Architecture profile |") = "" then
            Fail ("README.md has no architecture row; the check no longer "
                  & "matches the document it reads");
         end if;

         for Format in Model_Runner.GGUF.Tensor_Type loop
            if Model_Runner.Quantization.Is_Decodable (Format) then
               declare
                  Name : constant String :=
                    Model_Runner.GGUF.Type_Name (Format);
               begin
                  Result.Performed := Result.Performed + 1;
                  if not Holds_Word (Matrix, Name) then
                     Fail ("the engine decodes " & Name
                           & " but docs/support-matrix.md does not name it");
                  end if;

                  Result.Performed := Result.Performed + 1;
                  if not Holds_Word (Listed, Name) then
                     Fail ("the engine decodes " & Name
                           & " but the README's quantization row does not "
                           & "name it");
                  end if;
               end;
            end if;
         end loop;
      end;

      --  The backend's description of itself matches what it does.
      --
      --  Capabilities is a table the code publishes about the code, and
      --  nothing in this program consults it, so the two could disagree
      --  indefinitely without anything going wrong. Supports_Batched said
      --  False while Llama was calling Dispatch_Batch on every prefill.
      --
      --  It is checked against the same source the documents are: a format
      --  the engine decodes is a format the backend that runs it reads.
      declare
         Able : constant Model_Runner.Backend.Capabilities :=
           Model_Runner.Backend.CPU.Describe;
      begin
         for Format in Model_Runner.GGUF.Tensor_Type loop
            Result.Performed := Result.Performed + 1;
            if Model_Runner.Quantization.Is_Decodable (Format)
              /= Model_Runner.Backend.Supports (Able, Format)
            then
               Fail ("the CPU backend and the decoder disagree about "
                     & Model_Runner.GGUF.Type_Name (Format)
                     & ": decodable is "
                     & Boolean'Image
                         (Model_Runner.Quantization.Is_Decodable (Format))
                     & " and supported is "
                     & Boolean'Image
                         (Model_Runner.Backend.Supports (Able, Format)));
            end if;
         end loop;

         --  And the flags that name an operation, against whether the
         --  operation is there to call.
         Check (Able.Supports_Batched,
                "the CPU backend says it does not batch, and Llama batches "
                & "through it");
         Check (Able.Supports_Matrix_Vector,
                "the CPU backend says it cannot multiply a matrix by a "
                & "vector, which is the whole of what it is asked to do");
         Check (Able.Alignment >= 4,
                "the CPU backend asks for an alignment no tensor can have");
         Check (Able.Max_Workers = Model_Runner.Backend.CPU.Max_Workers,
                "the CPU backend reports a worker cap it does not have");
         Check (not Model_Runner.Backend.CPU.Describe (1).Supports_Parallel,
                "a one-worker pool says it runs in parallel");
         Check (Model_Runner.Backend.CPU.Describe (2).Supports_Parallel,
                "a two-worker pool says it does not run in parallel");
      end;

      --  Every value of the error metadata enumerations is used.
      --
      --  Param_Duration_Ns was declared and named nowhere else at all: a
      --  formatting rule for durations that no diagnostic asked for. Three
      --  of the five recovery classes were computed for every code and read
      --  by nothing, which is the same thing one layer up.
      --
      --  These are checked the way the accounting categories and the
      --  progress stages are, and for the same reason: each was found by
      --  hand after the ones beside it had already been fixed.
      declare
         Spec : constant String :=
           Contents ("src/library/model_runner-errors.ads");
         Body_Text : constant String :=
           Contents ("src/library/model_runner-errors.adb")
           & Contents ("src/library/model_runner-presentation.adb")
           & Contents ("src/library/model_runner-cli-driver.adb")
           & Contents ("src/library/model_runner-cli-execute.adb")
           & Contents ("src/library/model_runner-gguf-containers-reader.adb")
           & Contents ("src/library/model_runner-llama.adb")
           & Contents ("src/library/model_runner-generation.adb")
           & Contents ("src/library/model_runner-tokenizer.adb")
           & Contents ("src/library/model_runner-templates.adb")
           & Contents ("src/library/model_runner-sampling.adb");

         --  Whether the name is used, with nothing running on after it. The
         --  declaration itself is in the spec and the spec is not searched.
         function Used (Name : String) return Boolean is
         begin
            if Body_Text'Length < Name'Length then
               return False;
            end if;
            for Index in Body_Text'First .. Body_Text'Last - Name'Length + 1
            loop
               if Body_Text (Index .. Index + Name'Length - 1) = Name
                 and then (Index = Body_Text'First
                           or else not (Body_Text (Index - 1)
                                          in 'A' .. 'Z' | 'a' .. 'z'
                                             | '0' .. '9' | '_'))
                 and then (Index + Name'Length > Body_Text'Last
                           or else not (Body_Text (Index + Name'Length)
                                          in 'A' .. 'Z' | 'a' .. 'z'
                                             | '0' .. '9' | '_'))
               then
                  return True;
               end if;
            end loop;
            return False;
         end Used;

         procedure Each_Value (Kind : String) is
            Opening : constant String := "type " & Kind & " is";
            From    : Natural := 0;
            Upto    : Natural := 0;
            Named   : Natural := 0;
         begin
            for Index in Spec'First .. Spec'Last - Opening'Length + 1 loop
               if Spec (Index .. Index + Opening'Length - 1) = Opening then
                  From := Index + Opening'Length;
                  exit;
               end if;
            end loop;
            if From /= 0 then
               for Index in From .. Spec'Last - 1 loop
                  if Spec (Index .. Index + 1) = ");" then
                     Upto := Index;
                     exit;
                  end if;
               end loop;
            end if;

            Result.Performed := Result.Performed + 1;
            if From = 0 or else Upto = 0 then
               Fail (Kind & " has no values to check; the check no longer "
                     & "matches the source it reads");
               return;
            end if;

            declare
               Cursor : Natural := From;
            begin
               while Cursor <= Upto loop
                  declare
                     Start : Natural := Cursor;
                  begin
                     while Start <= Upto
                       and then not (Spec (Start) in 'A' .. 'Z')
                     loop
                        Start := Start + 1;
                     end loop;
                     exit when Start > Upto;

                     declare
                        Stop : Natural := Start;
                     begin
                        while Stop <= Upto
                          and then (Spec (Stop) in 'A' .. 'Z'
                                    or else Spec (Stop) in 'a' .. 'z'
                                    or else Spec (Stop) = '_')
                        loop
                           Stop := Stop + 1;
                        end loop;

                        Named := Named + 1;
                        Result.Performed := Result.Performed + 1;
                        if not Used (Spec (Start .. Stop - 1)) then
                           Fail ("the " & Kind & " value "
                                 & Spec (Start .. Stop - 1)
                                 & " is declared and used by nothing");
                        end if;
                        Cursor := Stop;
                     end;
                  end;
               end loop;
            end;

            Result.Performed := Result.Performed + 1;
            if Named = 0 then
               Fail ("no " & Kind & " values were found; the check no longer "
                     & "matches the source it reads");
            end if;
         end Each_Value;
      begin
         Each_Value ("Parameter_Kind");
         Each_Value ("Recovery_Class");
         Each_Value ("Severity_Level");
      end;

      --  And the session's own states, which are declared elsewhere and were
      --  the last enumeration of this kind with nothing watching it. Three
      --  of seven were entered by nobody, and two of those could not have
      --  been entered correctly: they described a request and not a session.
      declare
         Spec : constant String :=
           Contents ("src/library/model_runner-llama.ads");
         Body_Text : constant String :=
           Contents ("src/library/model_runner-llama.adb")
           & Contents ("src/library/model_runner-generation.adb");
         Opening : constant String := "type Session_State is";
         From    : Natural := 0;
         Upto    : Natural := 0;
         Named   : Natural := 0;
      begin
         for Index in Spec'First .. Spec'Last - Opening'Length + 1 loop
            if Spec (Index .. Index + Opening'Length - 1) = Opening then
               From := Index + Opening'Length;
               exit;
            end if;
         end loop;
         if From /= 0 then
            for Index in From .. Spec'Last - 1 loop
               if Spec (Index .. Index + 1) = ");" then
                  Upto := Index;
                  exit;
               end if;
            end loop;
         end if;

         Result.Performed := Result.Performed + 1;
         if From = 0 or else Upto = 0 then
            Fail ("Session_State has no values to check; the check no longer "
                  & "matches the source it reads");
         end if;

         declare
            Cursor : Natural := From;
         begin
            while Cursor <= Upto loop
               declare
                  Start : Natural := Cursor;
               begin
                  while Start <= Upto
                    and then not (Spec (Start) in 'A' .. 'Z')
                  loop
                     Start := Start + 1;
                  end loop;
                  exit when Start > Upto;

                  declare
                     Stop : Natural := Start;
                  begin
                     while Stop <= Upto
                       and then (Spec (Stop) in 'A' .. 'Z'
                                 or else Spec (Stop) in 'a' .. 'z'
                                 or else Spec (Stop) = '_')
                     loop
                        Stop := Stop + 1;
                     end loop;

                     Named := Named + 1;
                     Result.Performed := Result.Performed + 1;
                     if not Holds (Body_Text, ":= " & Spec (Start .. Stop - 1))
                       and then not Holds
                                      (Body_Text,
                                       ", L." & Spec (Start .. Stop - 1))
                     then
                        Fail ("the session state " & Spec (Start .. Stop - 1)
                              & " is declared and entered by nothing");
                     end if;
                     Cursor := Stop;
                  end;
               end;
            end loop;
         end;

         Result.Performed := Result.Performed + 1;
         if Named = 0 then
            Fail ("no session states were found; the check no longer matches "
                  & "the source it reads");
         end if;
      end;

      --  Every accounting category this program declares is charged.
      --
      --  A category nothing charges is a line of a memory report that reads
      --  zero for memory the program is holding, and a limit that does not
      --  count it. Seven of ten were in that position, including the KV
      --  cache, which is the largest thing a session allocates.
      --
      --  Read out of the enumeration and looked for in a charge. The
      --  category name appearing in a comment does not count, which is why
      --  this looks for it after a dot.
      declare
         Spec : constant String :=
           Contents ("src/library/model_runner-memory.ads");
         Body_Text : constant String :=
           Contents ("src/library/model_runner-llama.adb")
           & Contents ("src/library/model_runner-generation.adb")
           & Contents ("src/library/model_runner-gguf-containers-reader.adb")
           & Contents ("src/library/model_runner-tokenizer.adb")
           & Contents ("src/library/model_runner-cli-execute.adb");
         Opening : constant String := "type Category is";

         --  Whether Text charges Name: the name after a dot, with no
         --  identifier character running on after it.
         function Charged (Text, Name : String) return Boolean is
            Token : constant String := "." & Name;
         begin
            if Text'Length < Token'Length then
               return False;
            end if;
            for Index in Text'First .. Text'Last - Token'Length + 1 loop
               if Text (Index .. Index + Token'Length - 1) = Token
                 and then (Index + Token'Length > Text'Last
                           or else not (Text (Index + Token'Length)
                                          in 'A' .. 'Z' | 'a' .. 'z'
                                             | '0' .. '9' | '_'))
               then
                  return True;
               end if;
            end loop;
            return False;
         end Charged;
         From    : Natural := 0;
         Upto    : Natural := 0;
         Named   : Natural := 0;
      begin
         for Index in Spec'First .. Spec'Last - Opening'Length + 1 loop
            if Spec (Index .. Index + Opening'Length - 1) = Opening then
               From := Index + Opening'Length;
               exit;
            end if;
         end loop;

         if From /= 0 then
            for Index in From .. Spec'Last - 1 loop
               if Spec (Index .. Index + 1) = ");" then
                  Upto := Index;
                  exit;
               end if;
            end loop;
         end if;

         Result.Performed := Result.Performed + 1;
         if From = 0 or else Upto = 0 then
            Fail ("Memory.Category has no values to check; the check no "
                  & "longer matches the source it reads");
         end if;

         declare
            Cursor : Natural := From;
         begin
            while Cursor <= Upto loop
               declare
                  Start : Natural := Cursor;
               begin
                  while Start <= Upto
                    and then not (Spec (Start) in 'A' .. 'Z')
                  loop
                     Start := Start + 1;
                  end loop;
                  exit when Start > Upto;

                  declare
                     Stop : Natural := Start;
                  begin
                     while Stop <= Upto
                       and then (Spec (Stop) in 'A' .. 'Z'
                                 or else Spec (Stop) in 'a' .. 'z'
                                 or else Spec (Stop) = '_')
                     loop
                        Stop := Stop + 1;
                     end loop;

                     Named := Named + 1;
                     Result.Performed := Result.Performed + 1;

                     --  With nothing running on after it: KV_Cache passed
                     --  the first version of this check because the plan
                     --  has a field called KV_Cache_Bytes, which is the
                     --  size of the thing and not a charge for it.
                     if not Charged (Body_Text, Spec (Start .. Stop - 1)) then
                        Fail ("the accounting category "
                              & Spec (Start .. Stop - 1)
                              & " is declared and charged by nothing");
                     end if;
                     Cursor := Stop;
                  end;
               end;
            end loop;
         end;

         Result.Performed := Result.Performed + 1;
         if Named = 0 then
            Fail ("no accounting categories were found; the check no longer "
                  & "matches the source it reads");
         end if;
      end;

      --  And the finder finds. A catalog with a line the runtime refuses is
      --  written from the real one, and what comes back has to be that line.
      --
      --  Run every time rather than only when the catalog is broken,
      --  because a search that is only exercised on the day something
      --  breaks is a search nobody knows works. The planted line is the one
      --  that cost an afternoon: a placeholder named seconds, which the
      --  runtime refuses and which looks exactly like the dozen placeholders
      --  beside it that it accepts.
      declare
         Real    : constant String :=
           Contents ("resources/messages/catalog.txt");
         Planted : constant String := Path ("obj/catalog-planted.txt");

         --  A line with a key and no value, which the runtime refuses --
         --  the whole catalog, in every locale, which is the failure this
         --  search exists for.
         --
         --  Chosen because it is one line and it is understood. The fault
         --  that prompted all this was a placeholder named seconds, and
         --  what this repository can say about that is only what it
         --  measured: with that name in the English and pseudo-locale forms
         --  of one message the catalog stopped loading, and renaming it
         --  fixed it. Why is not established, and a search proved against a
         --  fault nobody can explain is a search nobody can trust.
         --
         --  Two other things were tried and are not faults of this kind: an
         --  unclosed placeholder leaves the catalog loading and renders
         --  wrongly, and a duplicated key does stop it loading but no
         --  single line accounts for it -- either of the two could go.
         Was : constant String :=
           "en.error.backend.closed = the backend is closed";
         Fault : constant String := "en.error.backend.planted_fault";
         Now   : constant String :=
           "en.error.backend.closed = the backend is closed"
           & Character'Val (10) & Fault;

         Handle : Ada.Text_IO.File_Type;
         At_Was : Natural := 0;
      begin
         Result.Performed := Result.Performed + 1;

         if Real'Length > 0 then
            At_Was := Ada.Strings.Fixed.Index (Real, Was);
         end if;

         if At_Was = 0 then
            Fail ("the catalog could not be read, or no longer carries the "
                  & "line this plants a fault in, so the search for what "
                  & "breaks a catalog was not exercised");
         else
            Ada.Text_IO.Create (Handle, Ada.Text_IO.Out_File, Planted);
            Ada.Text_IO.Put (Handle, Real (Real'First .. At_Was - 1));
            Ada.Text_IO.Put (Handle, Now);
            Ada.Text_IO.Put
              (Handle, Real (At_Was + Was'Length .. Real'Last));
            Ada.Text_IO.Close (Handle);

            declare
               Found : constant String :=
                 Offending_Line (Planted, Path ("obj/catalog-candidate.txt"));
            begin
               if Found /= Fault then
                  Fail ("the search for the line that breaks a catalog "
                        & "returned "
                        & (if Found = "" then "nothing"
                           else """" & Found & """")
                        & " where the planted line was """ & Fault
                        & """, so it would not find a real one either");
               end if;
            end;
         end if;
      end;

      --  A tool that publishes a timing publishes the load it was taken
      --  under.
      --
      --  The figures file is held to recording a load, which covers the
      --  numbers already published. This covers the tools: a new one, or an
      --  old one that starts printing a duration, would otherwise produce
      --  figures with no conditions attached and nothing would say so until
      --  somebody tried to compare two of them.
      --
      --  What counts as publishing a timing is printing seconds. What
      --  counts as reporting the load is naming Host_Load, which is the one
      --  reader for it.
      --
      --  `tests external-model` is the exception and states it: it
      --  publishes counts and answers rather than timings, and a line
      --  carrying a load is a line that differs between two runs of the
      --  same check -- which is what its published transcripts are compared
      --  against. Adding the field there broke that comparison, which is
      --  how the omission got a reason rather than staying an oversight.
      declare
         Excused : constant String := "tests/src/external_model.adb";

         procedure Publishes_A_Load (Which : String) is
            Body_Text : constant String := Contents (Which);
         begin
            Result.Performed := Result.Performed + 1;

            if Body_Text'Length = 0 then
               Fail (Which & " is not there, so what publishes the figures "
                     & "in this repository is not what this check reads");
            elsif not Project_Tools.Text.Contains (Body_Text, "seconds")
              and then not Project_Tools.Text.Contains (Body_Text, " s ")
            then
               Fail (Which & " no longer prints a timing, so it does not "
                     & "belong on the list this check reads");
            elsif not Project_Tools.Text.Contains (Body_Text, "Host_Load")
            then
               Fail (Which & " publishes a timing and does not read the "
                     & "load it was taken under, so its figures cannot be "
                     & "compared with any other");
            end if;
         end Publishes_A_Load;
      begin
         Publishes_A_Load ("tests/src/speed_run.adb");
         Publishes_A_Load ("tests/src/benchmarks.adb");

         --  And the one that is excused is still excused for the reason it
         --  gives, which is checked rather than remembered: an exception
         --  whose reason has quietly gone is an exception nobody decided on.
         Result.Performed := Result.Performed + 1;
         declare
            Body_Text : constant String := Contents (Excused);
         begin
            if Body_Text'Length = 0 then
               Fail (Excused & " is not there, and this check excuses it "
                     & "from reporting a load");
            elsif Project_Tools.Text.Contains (Body_Text, "Host_Load") then
               Fail (Excused & " reads the load now, so it is no longer the "
                     & "exception this check excuses; put it on the list "
                     & "instead");
            elsif not Project_Tools.Text.Contains
                        (Body_Text, "publishes counts")
            then
               Fail (Excused & " no longer says why it publishes no load, "
                     & "so the exception is one nobody decided on");
            end if;
         end;
      end;

      --  The crates this build is made of, beyond this one.
      --
      --  Every dependency here is pinned to a sibling working tree, so a
      --  build of this program compiles those trees as surely as it compiles
      --  this one -- and the checks above read this repository's object
      --  directories only. Twelve warnings in one of those crates were
      --  invisible from here, and a pinned crate that would not compile at
      --  all was found by a build failing rather than by anything saying so.
      --
      --  What is refused and what is only reported differ on purpose.
      --
      --  Stale evidence is refused, because that is a fact about this build:
      --  a pinned crate whose sources are newer than its objects has not
      --  been compiled since it changed, and nothing that depends on it can
      --  be vouched for either. That is exactly the state that stopped this
      --  program building at all, and it went unnamed.
      --
      --  Their warnings are listed rather than refused. This repository
      --  cannot hold another repository's tree to its own switches: a gate
      --  that went red for a sibling crate's warning would be a gate that
      --  passes on one machine and on no other, and would put this project's
      --  release behind somebody else's tidying. Listing them is what was
      --  missing; refusing them would be claiming an authority this
      --  repository does not have.
      declare
         use type Ada.Calendar.Time;
         use type Ada.Directories.File_Size;

         Crates  : Natural := 0;
         Unbuilt : Natural := 0;
         Noisy   : Natural := 0;

         --  Open only while the counts are being written down.
         Recording : Ada.Text_IO.File_Type;

         --  One pinned crate: is it compiled, and did it say anything?
         --  Both manifests pin most of the same crates, and a crate
         --  considered twice reports itself twice.
         Seen      : array (1 .. 32) of Ada.Strings.Unbounded.Unbounded_String;
         Seen_Last : Natural := 0;

         procedure Consider_Crate (Name : String; Place : String) is
            Behind : Natural := 0;
            Units  : Natural := 0;
            Said   : Natural := 0;

            function Evidence_Time (Unit : String) return Ada.Calendar.Time is
               Best : Ada.Calendar.Time := Ada.Calendar.Time_Of (1901, 1, 1);

               procedure Consider_Place (Where : String) is
                  Path : constant String := Where & "/" & Unit & ".ali";
               begin
                  if Ada.Directories.Exists (Path) then
                     declare
                        When_Made : constant Ada.Calendar.Time :=
                          Ada.Directories.Modification_Time (Path);
                     begin
                        if When_Made > Best then
                           Best := When_Made;
                        end if;
                     end;
                  end if;
               end Consider_Place;
            begin
               Consider_Place (Place & "/obj/development");
               Consider_Place (Place & "/obj/release");
               return Best;
            end Evidence_Time;

            procedure Consider (Path : String) is
               Simple : constant String := Ada.Directories.Simple_Name (Path);
               Unit   : constant String := Ada.Directories.Base_Name (Simple);
               Kind   : constant String := Ada.Directories.Extension (Simple);
            begin
               if Kind /= "adb" and then Kind /= "ads" then
                  return;
               end if;

               if Kind = "ads"
                 and then Ada.Directories.Exists
                            (Ada.Directories.Containing_Directory (Path)
                             & "/" & Unit & ".adb")
               then
                  return;
               end if;

               if Is_Subunit (Path) then
                  return;
               end if;

               declare
                  Made_At : constant Ada.Calendar.Time := Evidence_Time (Unit);
               begin
                  --  A source with no object here is not part of what this
                  --  build compiles. Sibling crates keep their own tests and
                  --  tools in the same tree, built by their own project
                  --  files into their own directories, and reporting those
                  --  as never compiled would be reporting on somebody
                  --  else's build. What can be said about this one is the
                  --  units it has objects for.
                  if Made_At = Ada.Calendar.Time_Of (1901, 1, 1) then
                     return;
                  end if;

                  if Has_Twin (Place, Path) then
                     return;
                  end if;

                  Units := Units + 1;

                  if Made_At < Ada.Directories.Modification_Time (Path) then
                     Behind := Behind + 1;
                  end if;
               end;
            end Consider;

            --  Sources, and the logs beside the objects, both a tree deep.
            procedure Walk (Where : String; Looking_For_Logs : Boolean) is
               Search : Ada.Directories.Search_Type;
               Item   : Ada.Directories.Directory_Entry_Type;
            begin
               if not Ada.Directories.Exists (Where) then
                  return;
               end if;

               Ada.Directories.Start_Search
                 (Search, Where, "",
                  [Ada.Directories.Ordinary_File => True,
                   Ada.Directories.Directory => True,
                   others => False]);
               while Ada.Directories.More_Entries (Search) loop
                  Ada.Directories.Get_Next_Entry (Search, Item);
                  declare
                     Simple : constant String :=
                       Ada.Directories.Simple_Name (Item);
                     Full : constant String :=
                       Ada.Directories.Full_Name (Item);
                  begin
                     --  A prover's shadow tree is not a build. gnatprove
                     --  writes its own copy of a compilation's diagnostics
                     --  under the object directory, so a dependency somebody
                     --  has proved counts every warning twice and the
                     --  recorded number goes stale for a reason that has
                     --  nothing to do with the crate getting noisier.
                     if Simple /= "." and then Simple /= ".."
                       and then Simple /= "gnatprove"
                       and then (Looking_For_Logs
                                 or else (Simple /= "obj"
                                          and then Simple /= "bin"
                                          and then Simple /= "alire"
                                          and then Simple /= "config"
                                          and then Simple /= ".git"))
                     then
                        if Ada.Directories."="
                             (Ada.Directories.Kind (Item),
                              Ada.Directories.Directory)
                        then
                           Walk (Full, Looking_For_Logs);
                        elsif Looking_For_Logs then
                           if Ada.Directories.Extension (Simple) = "stderr"
                             and then Ada.Directories.Size (Full) > 0
                           then
                              Said := Said + 1;
                           end if;
                        else
                           Consider (Full);
                        end if;
                     end if;
                  end;
               end loop;
               Ada.Directories.End_Search (Search);
            end Walk;
         begin
            if not Ada.Directories.Exists (Place) then
               return;
            end if;

            declare
               use Ada.Strings.Unbounded;
               Full : constant String :=
                 Ada.Directories.Full_Name (Place);
            begin
               for Index in 1 .. Seen_Last loop
                  if To_String (Seen (Index)) = Full then
                     return;
                  end if;
               end loop;

               if Seen_Last < Seen'Last then
                  Seen_Last := Seen_Last + 1;
                  Seen (Seen_Last) := To_Unbounded_String (Full);
               end if;
            end;

            Crates := Crates + 1;

            --  The whole tree rather than src, because a crate keeps its
            --  sources where it likes and this was reading one directory
            --  name: a crate that keeps them anywhere else was walked, found
            --  nothing, and reported nothing -- which reads exactly like a
            --  crate in good order.
            Walk (Place, Looking_For_Logs => False);
            Walk (Place & "/obj", Looking_For_Logs => True);

            --  A crate this build compiles nothing of is a crate this check
            --  is silent about, and silence and a clean bill have to look
            --  different. It read one directory name before and a crate
            --  keeping its sources anywhere else came out looking tidy.
            if Units = 0 then
               Fail ("the pinned crate " & Name
                     & " has no compiled unit this check could match to a "
                     & "source, so what it says about that crate is nothing "
                     & "at all");
            end if;

            if Units > 0 and then Behind > 0 then
               Unbuilt := Unbuilt + 1;
               Fail (Natural'Image (Behind) & " of" & Natural'Image (Units)
                     & " units of the pinned crate " & Name
                     & " are older than their sources, so this build rests "
                     & "on objects that do not match the tree it pins");
            end if;

            if Said > 0 then
               Noisy := Noisy + 1;
            end if;

            --  Written down rather than compared, when that is what was
            --  asked for. A number kept by hand is a number that drifts,
            --  and the alternative to this is reading a failure and editing
            --  a file to match it, which is the same work done less
            --  carefully.
            if Record_Warnings then
               Ada.Text_IO.Put_Line
                 (Recording, Name & Natural'Image (Said));
               return;
            end if;

            --  Against what was recorded, because sixty-three warnings
            --  listed every run are sixty-three warnings nobody reads, and
            --  a sixty-fourth arriving among them is invisible. What is
            --  refused is a rise: this repository cannot make another
            --  repository tidy, and it can notice the day one gets worse.
            declare
               Allowed : constant Integer := Recorded_Warnings (Name);
            begin
               if Allowed < 0 then
                  if Said > 0 then
                     Fail ("the pinned crate " & Name & " left"
                           & Natural'Image (Said)
                           & " compilations with warnings and is not in "
                           & "docs/dependency-warnings.txt; record what it "
                           & "is at, or make it quiet");
                  end if;
               elsif Said > Allowed then
                  Fail ("the pinned crate " & Name & " left"
                        & Natural'Image (Said)
                        & " compilations with warnings where"
                        & Integer'Image (Allowed)
                        & " was recorded, so this build is noisier than the "
                        & "one that was signed off");
               elsif Said < Allowed then
                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "  note: the pinned crate " & Name & " is down to"
                     & Natural'Image (Said) & " from"
                     & Integer'Image (Allowed)
                     & "; record the lower number in "
                     & "docs/dependency-warnings.txt");
               end if;
            end;
         end Consider_Crate;

         --  The pins, read from the manifest that names them. Two manifests,
         --  because the tests crate pins what it needs and the library pins
         --  what it needs, and neither list is the other.
         procedure Read_Pins (Manifest : String; Beside : String) is
            Handle : Ada.Text_IO.File_Type;
            In_Pin : Boolean := False;
         begin
            if not Ada.Directories.Exists (Manifest) then
               return;
            end if;

            Ada.Text_IO.Open (Handle, Ada.Text_IO.In_File, Manifest);
            while not Ada.Text_IO.End_Of_File (Handle) loop
               declare
                  Line : constant String := Ada.Text_IO.Get_Line (Handle);
                  Trimmed : constant String :=
                    Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both);
               begin
                  if Trimmed = "[[pins]]" then
                     In_Pin := True;
                  elsif Trimmed'Length > 0
                    and then Trimmed (Trimmed'First) = '['
                  then
                     In_Pin := False;
                  elsif In_Pin
                    and then Project_Tools.Text.Contains (Trimmed, "path =")
                  then
                     declare
                        Equals : constant Natural :=
                          Ada.Strings.Fixed.Index (Trimmed, "=");
                        Opens  : constant Natural :=
                          Ada.Strings.Fixed.Index (Trimmed, """");
                        Closes : constant Natural :=
                          Ada.Strings.Fixed.Index
                            (Trimmed, """", Ada.Strings.Backward);
                     begin
                        if Equals > Trimmed'First
                          and then Closes > Opens
                          and then Opens > 0
                        then
                           declare
                              Name : constant String :=
                                Ada.Strings.Fixed.Trim
                                  (Trimmed (Trimmed'First .. Equals - 1),
                                   Ada.Strings.Both);
                              Path : constant String :=
                                Trimmed (Opens + 1 .. Closes - 1);
                           begin
                              --  This repository pins itself from the tests
                              --  crate, and it is what the checks above are
                              --  about.
                              if Name /= "model_runner" then
                                 Consider_Crate (Name, Beside & "/" & Path);
                              end if;
                           end;
                        end if;
                     end;
                  end if;
               end;
            end loop;
            Ada.Text_IO.Close (Handle);
         exception
            when others =>
               if Ada.Text_IO.Is_Open (Handle) then
                  Ada.Text_IO.Close (Handle);
               end if;
         end Read_Pins;
      begin
         Result.Performed := Result.Performed + 1;

         if Record_Warnings then
            Ada.Text_IO.Create
              (Recording, Ada.Text_IO.Out_File,
               Root & "/docs/dependency-warnings.txt");
            Write_Preamble (Recording);
         end if;

         Read_Pins (Root & "/alire.toml", Root);
         Read_Pins (Root & "/tests/alire.toml", Root & "/tests");

         if Record_Warnings then
            Ada.Text_IO.Close (Recording);
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "  note: wrote docs/dependency-warnings.txt from"
               & Natural'Image (Crates) & " pinned crates");
         end if;

         if Crates = 0 then
            Fail ("no pinned crates were found, so this check is reading "
                  & "the manifests wrongly: this program is built from "
                  & "nine of them");
         end if;
      end;

      --  Every unit carries compilation evidence no older than the switches.
      --
      --  The check above reads the logs a compilation leaves behind, and a
      --  log is only written when a unit is compiled. So a unit nobody has
      --  compiled since a style switch was turned on has no log, and reads
      --  as clean -- which is how five hundred and forty-seven warnings sat
      --  in this tree while the gate said there were none. Fifty of ninety
      --  library sources had a log; the other forty were vouched for by
      --  nothing, and the tree could not be built from clean at all, which
      --  is why nobody found out.
      --
      --  What is checked is the .ali file, because that is written for every
      --  compilation whether or not anything was said, where a .stderr is
      --  not: one body in this tree has an object and no .stderr, so
      --  requiring a log per unit would fail on a unit that is perfectly
      --  well compiled. The .ali must be newer than its source and newer
      --  than every project file, since the project files are where the
      --  switches live: an .ali older than the switches was made under
      --  different ones and says nothing about these.
      --
      --  The remedy is a build from clean. That is the point: this check is
      --  how a tree that cannot be built from clean says so.
      declare
         use type Ada.Calendar.Time;

         Newest_Project : Ada.Calendar.Time :=
           Ada.Calendar.Time_Of (1901, 1, 1);

         Missing : Natural := 0;
         Stale   : Natural := 0;
         Named   : Natural := 0;

         --  Units with a body per platform, which are not judged: see
         --  Has_Twin. Counted so that the number is visible rather than the
         --  exemption being silent.
         Twinned : Natural := 0;

         --  The newest .ali for a unit across every object directory, or the
         --  epoch when there is none. Both build profiles are looked in,
         --  because either is a real build and neither is preferred here.
         function Evidence_Time (Unit : String) return Ada.Calendar.Time is
            Best : Ada.Calendar.Time := Ada.Calendar.Time_Of (1901, 1, 1);

            procedure Consider_Place (Place : String) is
               Path : constant String := Place & "/" & Unit & ".ali";
            begin
               if Ada.Directories.Exists (Path) then
                  declare
                     When_Made : constant Ada.Calendar.Time :=
                       Ada.Directories.Modification_Time (Path);
                  begin
                     if When_Made > Best then
                        Best := When_Made;
                     end if;
                  end;
               end if;
            end Consider_Place;
         begin
            Consider_Place (Root & "/obj/development");
            Consider_Place (Root & "/obj/release");
            Consider_Place (Root & "/tests/obj/development");
            Consider_Place (Root & "/tests/obj/release");
            Consider_Place (Root & "/tools/obj/development");
            Consider_Place (Root & "/tools/obj/release");
            return Best;
         end Evidence_Time;

         --  Every project file, wherever it sits, because a switch changed
         --  in any of them changes what a compilation would say.
         procedure Note_Projects (Place : String) is
            Search : Ada.Directories.Search_Type;
            Item   : Ada.Directories.Directory_Entry_Type;
         begin
            if not Ada.Directories.Exists (Place) then
               return;
            end if;

            Ada.Directories.Start_Search
              (Search, Place, "*.gpr",
               [Ada.Directories.Ordinary_File => True, others => False]);
            while Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Item);
               declare
                  When_Made : constant Ada.Calendar.Time :=
                    Ada.Directories.Modification_Time
                      (Ada.Directories.Full_Name (Item));
               begin
                  if When_Made > Newest_Project then
                     Newest_Project := When_Made;
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (Search);
         end Note_Projects;

         --  One source: what unit is it part of, and is that unit vouched
         --  for? A spec beside a body is compiled with the body and shares
         --  its evidence, so only the body is asked about.
         procedure Consider (Path : String) is
            Simple : constant String := Ada.Directories.Simple_Name (Path);
            Unit   : constant String :=
              Ada.Directories.Base_Name (Simple);
            Kind   : constant String := Ada.Directories.Extension (Simple);
         begin
            if Kind /= "adb" and then Kind /= "ads" then
               return;
            end if;

            if Kind = "ads"
              and then Ada.Directories.Exists
                         (Ada.Directories.Containing_Directory (Path)
                          & "/" & Unit & ".adb")
            then
               return;
            end if;

            if Kind = "adb" and then Is_Subunit (Path) then
               return;
            end if;

            Named := Named + 1;

            declare
               Made_At : constant Ada.Calendar.Time := Evidence_Time (Unit);
               Source_At : constant Ada.Calendar.Time :=
                 Ada.Directories.Modification_Time (Path);
            begin
               if Has_Twin (Root & "/src", Path)
                 or else Has_Twin (Root & "/tests/src", Path)
                 or else Has_Twin (Root & "/tools/src", Path)
               then
                  Twinned := Twinned + 1;
               elsif Made_At = Ada.Calendar.Time_Of (1901, 1, 1) then
                  Missing := Missing + 1;
                  if Missing <= 5 then
                     Fail (Unit & " has never been compiled here, so the "
                           & "warning check vouches for nothing in it; "
                           & "build from clean");
                  end if;
               elsif Made_At < Source_At or else Made_At < Newest_Project then
                  Stale := Stale + 1;
                  if Stale <= 5 then
                     Fail (Unit & " was last compiled before its source or "
                           & "the switches changed, so its warning log is "
                           & "evidence about a different build; build from "
                           & "clean");
                  end if;
               end if;
            end;
         end Consider;

         --  Sources lie in a tree rather than a directory: the platform
         --  bodies are three levels down.
         procedure Walk (Place : String) is
            Search : Ada.Directories.Search_Type;
            Item   : Ada.Directories.Directory_Entry_Type;
         begin
            if not Ada.Directories.Exists (Place) then
               return;
            end if;

            Ada.Directories.Start_Search
              (Search, Place, "",
               [Ada.Directories.Ordinary_File => True,
                Ada.Directories.Directory => True,
                others => False]);
            while Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Item);
               declare
                  Simple : constant String :=
                    Ada.Directories.Simple_Name (Item);
                  Full : constant String :=
                    Ada.Directories.Full_Name (Item);
               begin
                  if Simple /= "." and then Simple /= ".." then
                     if Ada.Directories."=" (Ada.Directories.Kind (Item),
                                             Ada.Directories.Directory)
                     then
                        Walk (Full);
                     else
                        Consider (Full);
                     end if;
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (Search);
         end Walk;
      begin
         Result.Performed := Result.Performed + 1;

         Note_Projects (Root);
         Note_Projects (Root & "/tests");
         Note_Projects (Root & "/tools");

         Walk (Root & "/src");
         Walk (Root & "/tests/src");
         Walk (Root & "/tools/src");

         if Named = 0 then
            Fail ("no sources were found to check for compilation evidence, "
                  & "so this check is looking in the wrong place");
         elsif Twinned = 0 then
            Fail ("no unit with a body per platform was found, and this "
                  & "program has several, so the exemption for them is "
                  & "matching nothing and the rest of this check may be "
                  & "matching nothing either");
         elsif Missing + Stale > 5 then
            Fail (Natural'Image (Missing + Stale) & " of"
                  & Natural'Image (Named)
                  & " units carry no current compilation evidence; the "
                  & "warning check speaks only for the rest");
         end if;
      end;

      --  The build left no warnings behind.
      --
      --  Every compilation writes its diagnostics to a .stderr log beside
      --  the object file, and until now the gate read none of them: six
      --  warnings and layout faults of mine reached the tree and were found
      --  only when the aggregate release checklist happened to run. That
      --  checklist read the tests' logs and the tools' -- never the
      --  library's, where forty-nine were waiting.
      declare
         Before : constant Natural := Result.Failed;
      begin
         Result.Performed := Result.Performed + 1;
         Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr (Root & "/obj");
         Result.Performed := Result.Performed + 1;
         Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr
           (Root & "/tests/obj");
         Result.Performed := Result.Performed + 1;
         Project_Tools.Tree_Checks.Require_No_Nonempty_Stderr
           (Root & "/tools/obj");
         pragma Unreferenced (Before);
      exception
         when others =>
            Fail ("the build left warnings behind; see the .stderr logs "
                  & "under obj");
      end;

      --  Every test that exists is registered, and there are still as many
      --  as there were.
      --
      --  A test procedure that nobody registers runs nothing and passes
      --  quietly, which is worse than not writing it: the suite counts one
      --  more success and covers one thing less. And a suite that shrinks is
      --  invisible to a runner that only asks whether what ran passed.
      declare
         Registered : Natural := 0;
         Declared   : Natural := 0;

         --  The floor. Raise it when the suite grows; it exists so that
         --  deleting tests has to be deliberate rather than unnoticed.
         Fewest : constant := 160;

         procedure Examine_Tests (Relative : String) is
            Text : constant String := Contents (Relative);

            --  Whether the file registers this name.
            function Registers (Name : String) return Boolean
            is (Holds (Text, "(T, " & Name & "'Access")
                or else Holds (Text, "(T, " & Name & "'access"));

            Cursor : Natural := Text'First;
         begin
            if Relative'Length < 4
              or else Relative (Relative'Last - 3 .. Relative'Last) /= ".adb"
              or else Text'Length = 0
              or else not Holds (Text, "Register_Routine")
            then
               return;
            end if;

            while Cursor <= Text'Last loop
               declare
                  Stop : Natural := Cursor;
               begin
                  while Stop <= Text'Last
                    and then Text (Stop) /= Character'Val (10)
                  loop
                     Stop := Stop + 1;
                  end loop;

                  declare
                     Line : constant String := Text (Cursor .. Stop - 1);
                  begin
                     if Holds (Line, "Register_Routine") then
                        Registered := Registered + 1;
                     end if;

                     --  A test procedure: declared at package level and
                     --  taking a test case, which is the shape AUnit needs.
                     if Line'Length > 16
                       and then Line (Line'First .. Line'First + 2) = "   "
                       and then T.Starts_With
                                  (Line (Line'First + 3 .. Line'Last),
                                   "procedure ")
                       and then Holds (Text,
                                       Line (Line'First + 13 .. Line'Last)
                                       & Character'Val (10)
                                       & "     (T")
                     then
                        declare
                           Name : constant String :=
                             Line (Line'First + 13 .. Line'Last);
                        begin
                           Declared := Declared + 1;
                           Result.Performed := Result.Performed + 1;
                           if not Registers (Name) then
                              Fail ("the test " & Name & " in " & Relative
                                    & " is written and registered by "
                                    & "nothing, so it never runs");
                           end if;
                        end;
                     end if;
                  end;

                  Cursor := Stop + 1;
               end;
            end loop;
         end Examine_Tests;

         procedure Examine_All_Tests is new For_Each_Source (Examine_Tests);
      begin
         Examine_All_Tests ("tests/src");

         Result.Performed := Result.Performed + 1;
         if Registered < Fewest then
            Fail ("the suite registers" & Natural'Image (Registered)
                  & " tests, fewer than the" & Natural'Image (Fewest)
                  & " it had; deleting tests is a decision, not a detail");
         end if;

         Result.Performed := Result.Performed + 1;
         if Declared = 0 then
            Fail ("no test procedures were found; the check no longer "
                  & "matches the sources it reads");
         end if;
      end;

      --  Every public subprogram has a caller.
      --
      --  An operation nothing calls is an operation nothing tests, and when
      --  its own documentation says where it is used it is worse than
      --  untested: Size_Changed said it was called before the tensor-loading
      --  stage, was called by nothing, and the reserved-codes list recorded
      --  the diagnostic it would have raised as unreachable on the strength
      --  of that sentence.
      --
      --  Written as a check because hand-scanning for this does not work.
      --  Four greps for it gave four different wrong answers, each confident.
      declare
         Bodies : Ada.Strings.Unbounded.Unbounded_String;
         Names  : Natural := 0;

         procedure Gather (Relative : String) is
         begin
            Ada.Strings.Unbounded.Append (Bodies, Contents (Relative));
            Ada.Strings.Unbounded.Append (Bodies, Character'Val (10));
         end Gather;

         procedure Gather_All is new For_Each_Source (Gather);

         --  Whether Text calls Name: the name, not part of a longer word,
         --  followed by an opening bracket or a semicolon, on a line that is
         --  not itself a declaration of it and not a comment.
         function Called (Text, Name : String) return Boolean is
            function Part_Of_A_Word (Letter : Character) return Boolean
            is (Letter in 'A' .. 'Z' or else Letter in 'a' .. 'z'
                or else Letter in '0' .. '9' or else Letter = '_');

            --  Whether a colon that is not part of ":=" comes next.
            function Colon_Follows (Text : String; From : Natural)
              return Boolean
            is
               Scan : Natural := From;
            begin
               while Scan <= Text'Last and then Text (Scan) = ' ' loop
                  Scan := Scan + 1;
               end loop;
               return Scan <= Text'Last
                 and then Text (Scan) = ':'
                 and then (Scan = Text'Last
                           or else Text (Scan + 1) /= '=');
            end Colon_Follows;
         begin
            if Text'Length < Name'Length then
               return False;
            end if;

            for Index in Text'First .. Text'Last - Name'Length + 1 loop
               if Text (Index .. Index + Name'Length - 1) = Name
                 and then (Index = Text'First
                           or else not Part_Of_A_Word (Text (Index - 1)))
               then
                  declare
                     After : constant Natural := Index + Name'Length;
                     Start : Natural := Index;
                  begin
                     --  Any mention on a line that is not a declaration is
                     --  a use. Requiring a bracket after the name looked
                     --  right and was not: a function without parameters is
                     --  called by naming it, so half the accessors in this
                     --  crate read as dead.
                     --
                     --  A name followed by a colon is being declared, not
                     --  used, and a constant's own declaration line has
                     --  nothing before the name to give it away. Not ":="
                     --  though: that is an assignment, and assigning to
                     --  something is using it.
                     if (After > Text'Last
                         or else not Part_Of_A_Word (Text (After)))
                       and then not (Colon_Follows (Text, Index + Name'Length))
                     then
                        while Start > Text'First
                          and then Text (Start - 1) /= Character'Val (10)
                        loop
                           Start := Start - 1;
                        end loop;

                        declare
                           Line : constant String :=
                             T.Trim (Text (Start .. Index - 1));
                        begin
                           if Line'Length < 2
                             or else (Line (Line'First .. Line'First + 1)
                                        /= "--"
                                      and then not T.Starts_With
                                                     (Line, "function")
                                      and then not T.Starts_With
                                                     (Line, "procedure")
                                      and then not T.Starts_With
                                                     (Line, "overriding")
                                      and then not T.Starts_With
                                                     (Line, "end")
                                      and then not T.Starts_With
                                                     (Line, "with"))
                           then
                              return True;
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end loop;
            return False;
         end Called;

         --  Public operations kept without a caller, and why. An operation
         --  that only a user of this crate would call belongs here; one that
         --  is simply unused does not, and gets removed instead.
         --  Row_Product is the compiled shader, which is a constant and not
         --  an operation: this check reads a spec by shape and cannot tell
         --  the two apart. It is handed to nothing yet, and what will hand
         --  it over is the piece of the device backend after this one.
         function Excused (Name : String) return Boolean
         is (Name in "Run_Process" | "Physical_Cores" | "Host_Name"
                     | "No_Color_Requested" | "Failure_Name" | "Interrupts"
                     | "Row_Product");

         procedure Examine (Relative : String) is
            Text   : constant String := Contents (Relative);
            Cursor : Natural := Text'First;
         begin
            --  Specs only. A body declares its own helpers at the same
            --  indentation and they are nobody's public interface.
            if Relative'Length < 4
              or else Relative (Relative'Last - 3 .. Relative'Last) /= ".ads"
              or else Text'Length = 0
            then
               return;
            end if;

            while Cursor <= Text'Last loop
               declare
                  Stop : Natural := Cursor;
               begin
                  while Stop <= Text'Last
                    and then Text (Stop) /= Character'Val (10)
                  loop
                     Stop := Stop + 1;
                  end loop;

                  declare
                     Line : constant String := Text (Cursor .. Stop - 1);
                     Head : Natural := 0;
                  begin
                     --  A public declaration: three spaces of indentation,
                     --  which is what the package level uses here.
                     if Line'Length > 14
                       and then Line (Line'First .. Line'First + 2) = "   "
                       and then Line (Line'First + 3) /= ' '
                     then
                        if T.Starts_With
                             (Line (Line'First + 3 .. Line'Last), "function ")
                        then
                           Head := Line'First + 12;
                        elsif T.Starts_With
                                (Line (Line'First + 3 .. Line'Last),
                                 "procedure ")
                        then
                           Head := Line'First + 13;

                        --  And a named constant, which carries a promise of
                        --  its own: a limit written into a spec is read as a
                        --  limit that holds. One said paths were bounded at
                        --  four thousand characters while the type holding
                        --  them stopped at five hundred and twelve.
                        elsif Holds (Line, ": constant") then
                           Head := Line'First + 3;
                        end if;
                     end if;

                     if Head /= 0 and then Head <= Line'Last then
                        declare
                           Tail : Natural := Head;
                        begin
                           while Tail <= Line'Last
                             and then (Line (Tail) in 'A' .. 'Z'
                                       or else Line (Tail) in 'a' .. 'z'
                                       or else Line (Tail) in '0' .. '9'
                                       or else Line (Tail) = '_')
                           loop
                              Tail := Tail + 1;
                           end loop;

                           if Tail > Head then
                              declare
                                 Name : constant String :=
                                   Line (Head .. Tail - 1);
                              begin
                                 Names := Names + 1;
                                 Result.Performed := Result.Performed + 1;
                                 if not Excused (Name)
                                   and then not Called
                                                  (Ada.Strings.Unbounded
                                                     .To_String (Bodies),
                                                   Name)
                                 then
                                    Fail ("the public operation " & Name
                                          & " in " & Relative
                                          & " is called by nothing");
                                 end if;
                              end;
                           end if;
                        end;
                     end if;
                  end;

                  Cursor := Stop + 1;
               end;
            end loop;
         end Examine;

         procedure Examine_All is new For_Each_Source (Examine);
      begin
         --  Every platform, not the one this build happens to use. A
         --  constant read only by the Windows body is read; leaving those
         --  out reported the mapping limit as dead because the POSIX body
         --  is where it is tested.
         Gather_All ("src/library");
         Gather_All ("src/platform/linux");
         Gather_All ("src/platform/macos");
         Gather_All ("src/platform/posix");
         Gather_All ("src/platform/windows");
         Gather_All ("src/platform/unsupported");
         Gather_All ("tests/src");
         Examine_All ("src/library");

         Result.Performed := Result.Performed + 1;
         if Names = 0 then
            Fail ("no public operations were found; the check no longer "
                  & "matches the tree it reads");
         end if;

      end;

      --  Every progress stage this program declares is published somewhere.
      --
      --  A stage nobody publishes is a stage an observer waits for forever.
      --  Five were in that position and none of them were found by anything:
      --  Converting_Tensor and Preparing_Kernels named steps this program
      --  does not take, Selecting_Backend named one it had only just gained,
      --  and Prompt_Rendered could only be published by the caller of
      --  generation, because generation is handed a prompt already rendered.
      --
      --  The stage names are read out of the enumerations and looked for in
      --  a Publish call. That is a weaker statement than watching a run make
      --  each one happen, and it is the one that costs no observer parameter
      --  on the command driver; the verbose trace is read by a test, which
      --  is the other half.
      declare
         Spec : constant String :=
           Contents ("src/library/model_runner-progress.ads");
         Body_Text : constant String :=
           Contents ("src/library/model_runner-generation.adb")
           & Contents ("src/library/model_runner-llama.adb")
           & Contents ("src/library/model_runner-gguf-containers-reader.adb")
           & Contents ("src/library/model_runner-cli-execute.adb");
         Named : Natural := 0;

         --  The literals between "type NAME is" and the ");" that ends it.
         procedure Each_Stage (Kind : String) is
            Opening : constant String := "type " & Kind & " is";
            From    : Natural := 0;
            Upto    : Natural := 0;
         begin
            if Spec'Length < Opening'Length then
               return;
            end if;
            for Index in Spec'First .. Spec'Last - Opening'Length + 1 loop
               if Spec (Index .. Index + Opening'Length - 1) = Opening then
                  From := Index + Opening'Length;
                  exit;
               end if;
            end loop;
            if From = 0 then
               return;
            end if;

            for Index in From .. Spec'Last - 1 loop
               if Spec (Index .. Index + 1) = ");" then
                  Upto := Index;
                  exit;
               end if;
            end loop;
            if Upto = 0 then
               return;
            end if;

            declare
               Cursor : Natural := From;
            begin
               while Cursor <= Upto loop
                  declare
                     Start : Natural := Cursor;
                  begin
                     while Start <= Upto
                       and then not (Spec (Start) in 'A' .. 'Z')
                     loop
                        Start := Start + 1;
                     end loop;
                     exit when Start > Upto;

                     declare
                        Stop : Natural := Start;
                     begin
                        while Stop <= Upto
                          and then (Spec (Stop) in 'A' .. 'Z'
                                    or else Spec (Stop) in 'a' .. 'z'
                                    or else Spec (Stop) = '_')
                        loop
                           Stop := Stop + 1;
                        end loop;

                        Named := Named + 1;
                        Result.Performed := Result.Performed + 1;
                        --  Preceded by a dot, so that Progress.Opening_Model
                        --  and P.Opening_Model both count and a comment
                        --  mentioning the stage by name does not.
                        if not Holds (Body_Text,
                                      "." & Spec (Start .. Stop - 1))
                        then
                           Fail ("the progress stage "
                                 & Spec (Start .. Stop - 1)
                                 & " is declared and published by nothing");
                        end if;
                        Cursor := Stop;
                     end;
                  end;
               end loop;
            end;
         end Each_Stage;
      begin
         Each_Stage ("Load_Stage");
         Each_Stage ("Generation_Stage");

         Result.Performed := Result.Performed + 1;
         if Named = 0 then
            Fail ("no progress stages were found; the check no longer "
                  & "matches the source it reads");
         end if;
      end;

      --  No help line writes out a list the code can generate.
      --
      --  Four value sets went stale one at a time this way, each found only
      --  after it had drifted: the tokenizer vocabularies, the decodable
      --  formats, "llama3 or chatml", and "auto, always or never" -- the
      --  last of which survived being fixed in the error message and stayed
      --  in the help beside it, in three locales, twice.
      --
      --  The names are asked of the code and looked for in the catalog. A
      --  help line that offers them has to take them as a parameter instead,
      --  which is the only form that cannot go stale.
      declare
         --  Every name the program can put in a list for itself.
         function Offered (Index : Positive) return String is
            Formats  : constant Natural :=
              Model_Runner.Templates.Chat_Format'Pos
                (Model_Runner.Templates.Chat_Format'Last) + 1;
            Backends : constant Natural :=
              Model_Runner.Backend.Backend_Kind'Pos
                (Model_Runner.Backend.Backend_Kind'Last) + 1;
         begin
            if Index <= Formats then
               return Model_Runner.Templates.Format_Name
                 (Model_Runner.Templates.Chat_Format'Val (Index - 1));
            elsif Index - Formats in 1 .. Backends then
               return Model_Runner.Backend.Backend_Name
                 (Model_Runner.Backend.Backend_Kind'Val
                    (Index - Formats - 1));
            else
               return Model_Runner.CLI.Options.Color_Name
                 (Model_Runner.CLI.Options.Color_Mode'Val
                    (Index - Formats - Backends - 1));
            end if;
         end Offered;

         Formats : constant Natural :=
           Model_Runner.Templates.Chat_Format'Pos
             (Model_Runner.Templates.Chat_Format'Last) + 1;
         Backends : constant Natural :=
           Model_Runner.Backend.Backend_Kind'Pos
             (Model_Runner.Backend.Backend_Kind'Last) + 1;

         Total : constant Natural :=
           Model_Runner.Templates.Chat_Format'Pos
             (Model_Runner.Templates.Chat_Format'Last) + 1
           + Model_Runner.Backend.Backend_Kind'Pos
               (Model_Runner.Backend.Backend_Kind'Last) + 1
           + Model_Runner.CLI.Options.Color_Mode'Pos
               (Model_Runner.CLI.Options.Color_Mode'Last) + 1;

         Catalog : constant String :=
           Contents ("resources/messages/catalog.txt");
         Cursor  : Natural := Catalog'First;
         Lines   : Natural := 0;

         function Part_Of_A_Word (Letter : Character) return Boolean
         is (Letter in 'A' .. 'Z' or else Letter in 'a' .. 'z'
             or else Letter in '0' .. '9' or else Letter = '_');

         --  Whether Text holds Token with nothing alphanumeric beside it.
         function Holds_Word (Text, Token : String) return Boolean is
         begin
            if Text'Length < Token'Length then
               return False;
            end if;
            for Index in Text'First .. Text'Last - Token'Length + 1 loop
               if Text (Index .. Index + Token'Length - 1) = Token
                 and then (Index = Text'First
                           or else not Part_Of_A_Word (Text (Index - 1)))
                 and then (Index + Token'Length > Text'Last
                           or else not Part_Of_A_Word
                                        (Text (Index + Token'Length)))
               then
                  return True;
               end if;
            end loop;
            return False;
         end Holds_Word;
      begin
         while Cursor <= Catalog'Last loop
            declare
               Stop : Natural := Cursor;
            begin
               while Stop <= Catalog'Last
                 and then Catalog (Stop) /= Character'Val (10)
               loop
                  Stop := Stop + 1;
               end loop;

               declare
                  Line : constant String := Catalog (Cursor .. Stop - 1);
               begin
                  if Holds (Line, ".help.") then
                     Lines := Lines + 1;

                     --  Two names from one set, not one. A help line saying
                     --  "never memory-map the model file" is using the
                     --  English word, and a rule that cannot tell the
                     --  difference is a rule nobody will keep. Two of them
                     --  side by side is a list, and a list is the thing that
                     --  goes stale.
                     --
                     --  A set with one member is therefore never caught.
                     --  That is the cost of not crying wolf, and the smaller
                     --  risk: one name cannot fall out of step with the rest
                     --  of a list it has to itself.
                     for Group in 1 .. 3 loop
                        declare
                           From  : constant Positive :=
                             (case Group is
                                when 1 => 1,
                                when 2 => Formats + 1,
                                when others => Formats + Backends + 1);
                           Upto  : constant Natural :=
                             (case Group is
                                when 1 => Formats,
                                when 2 => Formats + Backends,
                                when others => Total);
                           Seen  : Natural := 0;
                           First : Natural := 0;
                        begin
                           for Index in From .. Upto loop
                              if Holds_Word (Line, Offered (Index)) then
                                 Seen := Seen + 1;
                                 if First = 0 then
                                    First := Index;
                                 end if;
                              end if;
                           end loop;

                           Result.Performed := Result.Performed + 1;
                           if Seen >= 2 then
                              Fail ("a help line lists values the program "
                                    & "can list for itself, starting with "
                                    & Offered (First) & ": " & Line);
                           end if;
                        end;
                     end loop;
                  end if;
               end;

               Cursor := Stop + 1;
            end;
         end loop;

         Result.Performed := Result.Performed + 1;
         if Lines = 0 then
            Fail ("no help lines were found in the catalog; the check no "
                  & "longer matches the file it reads");
         end if;
      end;

      --  Every capability field is read by something.
      --
      --  Capabilities carries a rule in its comment: every field here is
      --  asked by something. That was a rule nobody enforced, which is what
      --  it was describing -- ten of eleven fields had no reader, and the one
      --  that mattered said the wrong thing for as long as it did.
      --
      --  The field names are read out of the record and looked for in the
      --  program, discounting the backend's own assignments to them. A field
      --  added without a reader fails here.
      declare
         Spec  : constant String :=
           Contents ("src/library/model_runner-backend.ads");
         Named : Natural := 0;

         --  Everything that could read the record, with the lines that fill
         --  it in taken out. An assignment is not a reader, and Describe is
         --  nothing but assignments; a field read only there is a field
         --  written for its own sake.
         --
         --  The backend's own spec counts, because Supports reads Formats
         --  there and callers go through it. An accessor is a reader.
         function Without_Assignments (Text : String) return String is
            Room   : String (1 .. Text'Length);
            Used   : Natural := 0;
            Cursor : Natural := Text'First;
         begin
            while Cursor <= Text'Last loop
               declare
                  Stop : Natural := Cursor;
               begin
                  while Stop <= Text'Last
                    and then Text (Stop) /= Character'Val (10)
                  loop
                     Stop := Stop + 1;
                  end loop;

                  declare
                     Line : constant String := Text (Cursor .. Stop - 1);
                  begin
                     if not Holds (Line, "Result.") then
                        Room (Used + 1 .. Used + Line'Length) := Line;
                        Used := Used + Line'Length + 1;
                        if Used <= Room'Length then
                           Room (Used) := Character'Val (10);
                        end if;
                     end if;
                  end;

                  Cursor := Stop + 1;
               end;
            end loop;
            return Room (1 .. Natural'Min (Used, Room'Length));
         end Without_Assignments;

         Program : constant String :=
           Without_Assignments
             (Contents ("src/library/model_runner-backend.ads")
              & Contents ("src/library/model_runner-backend-cpu.adb")
              & Contents ("src/library/model_runner-llama.adb")
              & Contents ("src/library/model_runner-cli-execute.adb"));

         --  The record's fields, between "type Capabilities is record" and
         --  the "end record" that closes it.
         function Fields return String is
            Opening : constant String := "type Capabilities is record";
            From    : Natural := 0;
         begin
            if Spec'Length < Opening'Length then
               return "";
            end if;
            for Index in Spec'First .. Spec'Last - Opening'Length + 1 loop
               if Spec (Index .. Index + Opening'Length - 1) = Opening then
                  From := Index + Opening'Length;
                  exit;
               end if;
            end loop;
            if From = 0 then
               return "";
            end if;
            for Index in From .. Spec'Last - 9 loop
               if Spec (Index .. Index + 9) = "end record" then
                  return Spec (From .. Index - 1);
               end if;
            end loop;
            return "";
         end Fields;

         Body_Text : constant String := Fields;
         Cursor    : Natural := Body_Text'First;
      begin
         Result.Performed := Result.Performed + 1;
         if Body_Text = "" then
            Fail ("Capabilities has no fields to check; the check no longer "
                  & "matches the source it reads");
         end if;

         while Cursor <= Body_Text'Last loop
            declare
               Stop : Natural := Cursor;
            begin
               while Stop <= Body_Text'Last
                 and then Body_Text (Stop) /= Character'Val (10)
               loop
                  Stop := Stop + 1;
               end loop;

               declare
                  Line  : constant String :=
                    T.Trim (Body_Text (Cursor .. Stop - 1));
                  Colon : Natural := 0;
               begin
                  for Index in Line'Range loop
                     if Line (Index) = ':' then
                        Colon := Index;
                        exit;
                     end if;
                  end loop;

                  --  A field declaration, not a comment or a blank line.
                  if Colon > Line'First
                    and then Line'Length > 2
                    and then Line (Line'First .. Line'First + 1) /= "--"
                  then
                     declare
                        Name : constant String :=
                          T.Trim (Line (Line'First .. Colon - 1));
                     begin
                        Named := Named + 1;
                        Result.Performed := Result.Performed + 1;
                        if not Holds (Program, "." & Name) then
                           Fail ("the capability field " & Name
                                 & " is filled in and read by nothing; give "
                                 & "it a reader or take it out");
                        end if;
                     end;
                  end if;
               end;

               Cursor := Stop + 1;
            end;
         end loop;

         Result.Performed := Result.Performed + 1;
         if Named = 0 then
            Fail ("no capability fields were found; the check no longer "
                  & "matches the source it reads");
         end if;
      end;

      --  Every chat-template row says what running it actually does.
      --
      --  This was the last hand-maintained registry: a table of claims about
      --  the template subset, beside the code rather than about it. It said
      --  `set` and the filters were rejected for as long as they had been
      --  implemented, and nothing could tell.
      --
      --  No check can invent a row for a construct somebody adds. What this
      --  one does is stop a row outliving what it says. Every row must have
      --  an example carrying its label, every example is compiled and
      --  rendered, and where it ends must be what its row claims -- so a
      --  construct that moves into the subset fails while its row still calls
      --  it refused, and one that moves out fails while its row still calls
      --  it implemented.
      declare
         Matrix : constant String := Contents ("docs/support-matrix.md");
         Seen   : array (1 .. Template_Registry.Count) of Boolean :=
           [others => False];
         Rows   : Natural := 0;

         Body_Text : constant String :=
           Section (Matrix, "## Chat-template constructs");
         Cursor    : Natural := Body_Text'First;
      begin
         Result.Performed := Result.Performed + 1;
         if Body_Text = "" then
            Fail ("docs/support-matrix.md has no chat-template section; the "
                  & "check no longer matches the document it reads");
         end if;

         while Cursor <= Body_Text'Last loop
            declare
               Stop : Natural := Cursor;
            begin
               while Stop <= Body_Text'Last
                 and then Body_Text (Stop) /= Character'Val (10)
               loop
                  Stop := Stop + 1;
               end loop;

               declare
                  Line : constant String := Body_Text (Cursor .. Stop - 1);
                  Bar  : Natural := 0;
               begin
                  --  A row, not the heading and not the rule under it.
                  if Line'Length > 4 and then Line (Line'First) = '|'
                    and then Line (Line'First + 2) /= '-'
                    and then not Holds (Line, "| Construct |")
                  then
                     --  The cell ends at the first bar that is not escaped.
                     --  A row about the filter syntax writes its pipes as
                     --  \| so the table renders, and splitting on those cut
                     --  the label in half.
                     for Index in Line'First + 1 .. Line'Last loop
                        if Line (Index) = '|'
                          and then Line (Index - 1) /= '\'
                        then
                           Bar := Index;
                           exit;
                        end if;
                     end loop;

                     if Bar = 0 then
                        Result.Performed := Result.Performed + 1;
                        Fail ("a chat-template row has one cell: " & Line);
                     else
                        declare
                           Label : constant String :=
                             T.Trim (Line (Line'First + 1 .. Bar - 1));
                           State : constant String :=
                             Line (Bar + 1 .. Line'Last);
                           Want  : Template_Registry.Outcome :=
                             Template_Registry.Works;
                           Found : Natural := 0;
                        begin
                           Rows := Rows + 1;

                           --  What the row claims, read from the front of
                           --  the state cell rather than from anywhere in
                           --  it. A row gives its verdict first and
                           --  explains afterwards, and an explanation that
                           --  mentions another verdict must not be able to
                           --  change the one being checked.
                           if T.Starts_With (T.Trim (State), "Implemented")
                           then
                              Want := Template_Registry.Works;
                           elsif Holds (State, "at compile time") then
                              Want := Template_Registry.Refused_At_Compile;
                           elsif Holds (State, "when evaluated") then
                              Want := Template_Registry.Refused_At_Render;
                           else
                              Result.Performed := Result.Performed + 1;
                              Fail ("the chat-template row """ & Label
                                    & """ does not say what it does: "
                                    & State);
                           end if;

                           for Index in 1 .. Template_Registry.Count loop
                              if Template_Registry.Item (Index).Label.all
                                = Label
                              then
                                 Found := Index;
                                 Seen (Index) := True;
                              end if;
                           end loop;

                           Result.Performed := Result.Performed + 1;
                           if Found = 0 then
                              Fail ("no worked example for the chat-template "
                                    & "row """ & Label & """");
                           else
                              declare
                                 Detail : Template_Registry.Text_Access;
                                 Got    : constant Template_Registry.Outcome :=
                                   Template_Registry.Run
                                     (Template_Registry.Item
                                        (Found).Source.all, Detail);
                              begin
                                 Result.Performed := Result.Performed + 1;
                                 if Got /= Want then
                                    Fail ("the row """ & Label
                                          & """ says "
                                          & Template_Registry.Outcome'Image
                                              (Want)
                                          & " but its example is "
                                          & Template_Registry.Outcome'Image
                                              (Got)
                                          & (if Detail = null then ""
                                             else " (" & Detail.all & ")"));
                                 end if;

                                 --  And the example agrees with the state the
                                 --  registry records, so that a row edited to
                                 --  match a changed example is not enough.
                                 Result.Performed := Result.Performed + 1;
                                 if Got /= Template_Registry.Item (Found).State
                                 then
                                    Fail ("the example for """ & Label
                                          & """ does not do what the registry "
                                          & "says it does");
                                 end if;
                              end;
                           end if;
                        end;
                     end if;
                  end if;
               end;

               Cursor := Stop + 1;
            end;
         end loop;

         --  A row for every example, as well as an example for every row: an
         --  example left behind by a deleted row would otherwise go on
         --  passing while documenting nothing.
         for Index in 1 .. Template_Registry.Count loop
            Result.Performed := Result.Performed + 1;
            if not Seen (Index) then
               Fail ("the worked example """
                     & Template_Registry.Item (Index).Label.all
                     & """ matches no chat-template row");
            end if;
         end loop;

         Result.Performed := Result.Performed + 1;
         if Rows = 0 then
            Fail ("the chat-template section has no rows; the check no "
                  & "longer matches the document it reads");
         end if;
      end;

      --  Every vocabulary the tokenizer accepts is named in the matrix.
      --
      --  The matrix said `llama` and "everything else rejected" for as long
      --  as byte-pair encoding had been implemented, with a row further down
      --  the same file describing its six cutting rules. Nothing could have
      --  caught that, because nothing tied the table to the code: a reader
      --  who trusted it would have concluded their model was unsupported.
      --
      --  So the names are read out of the source rather than listed here.
      --  Listing them here would be the same table again, going stale in the
      --  same way, one file further from the code.
      declare
         Matrix : constant String := Contents ("docs/support-matrix.md");
         Source : constant String :=
           Contents ("src/library/model_runner-tokenizer.adb");
         Reader : constant String :=
           Contents ("tests/src/reference_tokenizer.adb");
         Quote  : constant Character := '"';

         --  Report whether Text holds Token.
         function Holds (Text, Token : String) return Boolean is
         begin
            if Text'Length < Token'Length then
               return False;
            end if;
            for Index in Text'First .. Text'Last - Token'Length + 1 loop
               if Text (Index .. Index + Token'Length - 1) = Token then
                  return True;
               end if;
            end loop;
            return False;
         end Holds;

         --  Each literal compared against Variable, checked against the
         --  matrix. A comparison against the empty string is the "absent"
         --  case, which has no name to print.
         procedure Accepted_Names (Variable : String) is
            Needle : constant String := Variable & " = """;
            Index  : Natural := Source'First;
            Found  : Natural := 0;
         begin
            while Index <= Source'Last - Needle'Length loop
               if Source (Index .. Index + Needle'Length - 1) = Needle then
                  declare
                     From : constant Natural := Index + Needle'Length;
                     Stop : Natural := From;
                  begin
                     while Stop <= Source'Last
                       and then Source (Stop) /= '"'
                     loop
                        Stop := Stop + 1;
                     end loop;

                     if Stop > From then
                        Found := Found + 1;
                        Result.Performed := Result.Performed + 1;
                        if not Holds (Matrix,
                                      "`" & Source (From .. Stop - 1) & "`")
                        then
                           Fail ("the tokenizer accepts "
                                 & Source (From .. Stop - 1)
                                 & " but docs/support-matrix.md does not "
                                 & "name it");
                        end if;
                     end if;
                     Index := Stop + 1;
                  end;
               else
                  Index := Index + 1;
               end if;
            end loop;

            --  A rename in the source that this stopped matching would
            --  otherwise pass by finding nothing at all.
            Result.Performed := Result.Performed + 1;
            if Found = 0 then
               Fail ("no vocabulary names found for " & Variable
                     & " in the tokenizer; the check no longer matches the "
                     & "source it reads");
            end if;
         end Accepted_Names;
         --  And every cutting rule the engine accepts by name is accepted
         --  by the independent reader too.
         --
         --  The two carry their own tables from a name to a rule and nothing
         --  compared them. A name mapped one way in the engine and another
         --  way in the reader would agree with nothing and be caught by
         --  nothing, because the agreement test drives a dozen names and not
         --  one test per name; a name in the engine and absent from the
         --  reader is worse still, because the reader answers zero tokens
         --  for a vocabulary it cannot read.
         procedure Same_Rules is
            Needle : constant String := "Cutting = " & Quote;
            Index  : Natural := Source'First;
            Found  : Natural := 0;
         begin
            while Index <= Source'Last - Needle'Length loop
               if Source (Index .. Index + Needle'Length - 1) = Needle then
                  declare
                     From : constant Natural := Index + Needle'Length;
                     Stop : Natural := From;
                  begin
                     while Stop <= Source'Last
                       and then Source (Stop) /= Quote
                     loop
                        Stop := Stop + 1;
                     end loop;

                     if Stop > From then
                        Found := Found + 1;
                        Result.Performed := Result.Performed + 1;
                        if not Holds (Reader,
                                      Needle & Source (From .. Stop - 1)
                                      & Quote)
                        then
                           Fail ("the tokenizer accepts "
                                 & Source (From .. Stop - 1)
                                 & " but the independent reader in "
                                 & "tests/src/reference_tokenizer.adb does "
                                 & "not");
                        end if;
                     end if;
                     Index := Stop + 1;
                  end;
               else
                  Index := Index + 1;
               end if;
            end loop;

            Result.Performed := Result.Performed + 1;
            if Found = 0 then
               Fail ("no cutting rules found in the tokenizer; the check no "
                     & "longer matches the source it reads");
            end if;
         end Same_Rules;
      begin
         Accepted_Names ("Name");
         Accepted_Names ("Cutting");
         Same_Rules;
      end;

      --  The generated error-code reference must be current: a stale committed
      --  file is a failure, not a surprise at release time.
      Check (Docs_Generation.Error_Reference_Is_Current (Root),
             "docs/error-codes.md is stale; run 'tests docs'");

      --  Which diagnostics the program can actually emit.
      --
      --  A code that is declared, catalogued in every locale and printed in
      --  docs/error-codes.md, but produced nowhere, reads to anyone using that
      --  reference as a diagnostic they might see. Thirty-one of them were.
      --  Six turned out to be real gaps and are now produced; the rest are
      --  kept deliberately and listed here, so that the next one to appear has
      --  to be accounted for rather than joining them quietly.
      --
      --  They fall into two kinds. Superseded: a more precise diagnostic is
      --  raised instead -- a closed session reports Lifecycle_Invalid_State
      --  and names the state, a vocabulary that does not match its embedding
      --  reports the tensor shape, an out-of-range --threads reports the
      --  option. Unreachable: the condition cannot arise -- there is no
      --  merge table in a SentencePiece vocabulary, and Conversation.Role is
      --  an enumeration.

      --
      --  Backend_Unknown was on that second list, with the reason "there is
      --  no --backend to be invalid". There is now, and a name this build
      --  does not have raises it.
      declare
         Produced : array (E.Error_Code) of Boolean := [others => False];

         --  The literal as written in a call, matched without regard to
         --  case: 'Image gives CLI_INVALID_LOCALE where the body says
         --  CLI_Invalid_Locale, and deriving one from the other means
         --  guessing which parts are acronyms.
         function Ada_Name (Code : E.Error_Code) return String
         is (E.Error_Code'Image (Code));

         --  Report whether Text contains Token.
         function Holds (Text, Token : String) return Boolean is
         begin
            if Text'Length < Token'Length then
               return False;
            end if;
            for Index in Text'First .. Text'Last - Token'Length + 1 loop
               if Text (Index .. Index + Token'Length - 1) = Token then
                  return True;
               end if;
            end loop;
            return False;
         end Holds;

         procedure Note_Codes (Relative : String) is
            Text : constant String := Contents (Relative);
         begin
            --  Bodies only, and not the registry itself: errors.adb names
            --  every code in its severity and recovery tables, so counting a
            --  mention there would call all of them produced.
            if Relative'Length > 4
              and then Relative (Relative'Last - 3 .. Relative'Last) = ".adb"
              and then not T.Ends_With (Relative, "model_runner-errors.adb")
            then
               for Code in E.Error_Code loop
                  if not Produced (Code)
                    and then Holds
                               (T.To_Lower (Text),
                                T.To_Lower (Ada_Name (Code)))
                  then
                     Produced (Code) := True;
                  end if;
               end loop;
            end if;
         end Note_Codes;

         procedure Scan is new For_Each_Source (Note_Codes);

      begin
         Scan ("src/library");
         Scan ("src/platform");

         for Code in E.Error_Code loop
            if Code /= E.No_Error then
               Result.Performed := Result.Performed + 1;

               if Produced (Code) and then Reserved_Codes.Is_Reserved (Code) then
                  Fail
                    (Ada_Name (Code)
                     & " is produced now; take it off the reserved list");
               elsif not Produced (Code) and then not Reserved_Codes.Is_Reserved (Code) then
                  Fail
                    (Ada_Name (Code)
                     & " is declared and produced nowhere; either produce it"
                     & " or put it on the reserved list with a reason");
               end if;
            end if;
         end loop;
      end;

      --  And every code a test reaches, or a reason it does not.
      --
      --  The check above asks whether a code appears in the source, and a
      --  raise nobody reaches appears there exactly as a raise everybody
      --  reaches does. Seventeen codes were in that state and nothing said
      --  so -- refusals written and never made to happen, which is a promise
      --  the program has not been asked to keep. Unreached_Codes carries the
      --  ones that remain with why, and this holds it in both directions.
      declare
         --  The enumeration image, which is how a test names a code in
         --  source: the same spelling the sibling check uses.
         function Ada_Name (Code : E.Error_Code) return String
         is (E.Error_Code'Image (Code));

         Named : array (E.Error_Code) of Boolean := [others => False];

         --  A file with its comments taken out and folded to lower case.
         --
         --  Folded because the enumeration image is upper case and a test
         --  writes the declared spelling; comparing the two as they stand
         --  found nothing and reported every code unreached. Comments out
         --  because a code discussed in prose is not a code a test reaches,
         --  and one mentioned in a registry's own header read as reached.
         --  A double hyphen inside a string literal would cut the line
         --  short here, which costs a name and never invents one.
         function Code_Bearing (Relative : String) return String is
            Text  : constant String := Contents (Relative);
            Room  : String (1 .. Text'Length);
            Used  : Natural := 0;
            Index : Natural := Text'First;
         begin
            while Index <= Text'Last loop
               if Index < Text'Last
                 and then Text (Index) = '-'
                 and then Text (Index + 1) = '-'
               then
                  while Index <= Text'Last
                    and then Text (Index) /= Character'Val (10)
                  loop
                     Index := Index + 1;
                  end loop;
               else
                  Used := Used + 1;
                  Room (Used) := Text (Index);
                  Index := Index + 1;
               end if;
            end loop;

            return T.To_Lower (Room (1 .. Used));
         end Code_Bearing;

         procedure Visit_Naming (Relative : String) is
            Text : constant String := Code_Bearing (Relative);
         begin
            --  The two registries name every code by construction, and
            --  docs_generation walks the whole type. Counting them would
            --  make every code look reached.
            if Relative = "tests/src/reserved_codes.adb"
              or else Relative = "tests/src/unreached_codes.adb"
              or else Relative = "tests/src/docs_generation.adb"
              or else Relative = "tests/src/checks.adb"
            then
               return;
            end if;

            for Code in E.Error_Code loop
               declare
                  Word : constant String := T.To_Lower (Ada_Name (Code));
               begin
                  for Index in Text'First .. Text'Last - Word'Length + 1 loop
                     if Text (Index .. Index + Word'Length - 1) = Word then
                        Named (Code) := True;
                        exit;
                     end if;
                  end loop;
               end;
            end loop;
         end Visit_Naming;

         procedure Scan_Naming is new For_Each_Source (Visit_Naming);
      begin
         Scan_Naming ("tests/src");

         for Code in E.Error_Code loop
            if Code /= E.No_Error
              and then not Reserved_Codes.Is_Reserved (Code)
            then
               Result.Performed := Result.Performed + 1;

               if Named (Code) and then Unreached_Codes.Is_Unreached (Code)
               then
                  Fail (Ada_Name (Code)
                        & " is reached by a test now; take it off the "
                        & "unreached list");
               elsif not Named (Code)
                 and then not Unreached_Codes.Is_Unreached (Code)
               then
                  Fail (Ada_Name (Code)
                        & " is raised and no test names it; either reach it "
                        & "or put it on the unreached list with a reason");
               end if;
            end if;
         end loop;
      end;

      --  A count written into prose drifts the moment a code is added, and it
      --  did: the documents claimed 147 codes for some time after there were
      --  148. The number is cheap to derive, so it is checked rather than
      --  trusted.
      declare
         Total : Natural := 0;

         --  The number written immediately before Phrase, or zero when the
         --  phrase does not appear. A line may be wrapped between the number
         --  and the phrase, so the gap is any run of white space.
         function Stated (Text : String; Phrase : String) return Natural is
            Last : Natural;
            Stop : Natural;
            Value : Natural := 0;
            Scale : Natural := 1;
         begin
            if Phrase'Length > Text'Length then
               return 0;
            end if;

            for Start in Text'First .. Text'Last - Phrase'Length + 1 loop
               if Text (Start .. Start + Phrase'Length - 1) = Phrase then
                  Last := Start - 1;
                  while Last >= Text'First
                    and then (Text (Last) = ' '
                              or else Text (Last) = ASCII.LF
                              or else Text (Last) = ASCII.CR)
                  loop
                     Last := Last - 1;
                  end loop;

                  Stop := Last;
                  while Stop >= Text'First
                    and then Text (Stop) in '0' .. '9'
                  loop
                     Stop := Stop - 1;
                  end loop;

                  if Stop < Last then
                     for Index in reverse Stop + 1 .. Last loop
                        Value :=
                          Value
                          + Scale
                            * (Character'Pos (Text (Index))
                               - Character'Pos ('0'));
                        Scale := Scale * 10;
                     end loop;
                     return Value;
                  end if;
               end if;
            end loop;

            return 0;
         end Stated;

         --  Report a document whose stated count is not the real one.
         procedure Agrees (Relative : String; Phrase : String) is
            Said : constant Natural := Stated (Contents (Relative), Phrase);
         begin
            Result.Performed := Result.Performed + 1;
            if Said /= Total then
               Fail
                 (Relative & " says" & Natural'Image (Said) & " "
                  & Phrase & " but there are" & Natural'Image (Total));
            end if;
         end Agrees;
      begin
         for Code in E.Error_Code loop
            if Code /= E.No_Error then
               Total := Total + 1;
            end if;
         end loop;

         Agrees ("README.md", "diagnostic codes");
         Agrees ("CHANGELOG.md", "diagnostic");
      end;

      --  Every value a diagnostic message names is attached somewhere.
      --
      --  A message saying "{limit} bytes" needs a parameter called limit, and
      --  without one the renderer cannot fill the message: it hands back the
      --  emergency form, and the reader sees <gguf.string_too_long> where the
      --  sentence belonged. Visible, which is the good part, and invisible to
      --  everybody until the day that code is first raised, which is not.
      --
      --  What this catches is a name nothing attaches anywhere -- a message
      --  inventing a value, or an attachment renamed on every side but the
      --  catalog. What it does not catch is the same name attached by some
      --  other diagnostic than the one whose message asks: "option" is added
      --  in two places, and renaming it in one leaves this quiet. Tying each
      --  name to the code that raises it would need to know which Make each
      --  Add belongs to, which is more than reading the text can say.
      --
      --  Reserved codes are skipped: nothing raises them, so nothing can
      --  attach anything to them.
      declare
         Catalog : constant String := Contents ("resources/messages/catalog.txt");

         Max_Names : constant := 128;
         Max_Name  : constant := 48;

         type Name_Record is record
            Text  : String (1 .. Max_Name) := [others => ' '];
            Last  : Natural := 0;
            Owner : String (1 .. 64) := [others => ' '];
            Owner_Last : Natural := 0;
            Found : Boolean := False;
         end record;

         Names : array (1 .. Max_Names) of Name_Record;
         Used  : Natural := 0;

         --  Remember a placeholder and which message asked for it.
         procedure Note (Name, Key : String) is
         begin
            if Name'Length = 0 or else Name'Length > Max_Name
              or else Key'Length > 64
            then
               return;
            end if;

            for Index in 1 .. Used loop
               if Names (Index).Text (1 .. Names (Index).Last) = Name then
                  return;
               end if;
            end loop;

            if Used < Max_Names then
               Used := Used + 1;
               Names (Used).Text (1 .. Name'Length) := Name;
               Names (Used).Last := Name'Length;
               Names (Used).Owner (1 .. Key'Length) := Key;
               Names (Used).Owner_Last := Key'Length;
            end if;
         end Note;

         --  Collect the placeholders of one message.
         procedure Collect (Key : String) is
            Marker : constant String := "en." & Key & " =";
            Start  : Natural := 0;
            Stop   : Natural;
         begin
            for Index in Catalog'First
              .. Catalog'Last - Marker'Length + 1
            loop
               if Catalog (Index .. Index + Marker'Length - 1) = Marker then
                  Start := Index;
                  exit;
               end if;
            end loop;

            if Start = 0 then
               return;
            end if;

            Stop := Start;
            while Stop <= Catalog'Last
              and then Catalog (Stop) /= Character'Val (10)
            loop
               Stop := Stop + 1;
            end loop;

            declare
               Line  : constant String := Catalog (Start .. Stop - 1);
               Index : Natural := Line'First;
            begin
               while Index < Line'Last loop
                  if Line (Index) = '{' then
                     declare
                        Close : Natural := Index + 1;
                     begin
                        while Close <= Line'Last
                          and then Line (Close) /= '}'
                        loop
                           Close := Close + 1;
                        end loop;

                        if Close <= Line'Last then
                           Note (Line (Index + 1 .. Close - 1), Key);
                           Index := Close;
                        end if;
                     end;
                  end if;

                  Index := Index + 1;
               end loop;
            end;
         end Collect;

         --  Mark the ones a source attaches.
         procedure Visit_Supplier (Relative : String) is
            Text : constant String := Contents (Relative);
         begin
            Result.Performed := Result.Performed + 1;

            for Index in 1 .. Used loop
               if not Names (Index).Found
                 and then Holds
                            (Text,
                             """" & Names (Index).Text (1 .. Names (Index).Last)
                             & """")
               then
                  Names (Index).Found := True;
               end if;
            end loop;
         end Visit_Supplier;

         procedure Scan_Suppliers is new For_Each_Source (Visit_Supplier);
      begin
         for Code in E.Error_Code loop
            if Code /= E.No_Error and then not Reserved_Codes.Is_Reserved (Code)
            then
               Collect (E.Message_Key (Code));
            end if;
         end loop;

         Scan_Suppliers ("src");

         for Index in 1 .. Used loop
            Result.Performed := Result.Performed + 1;

            if not Names (Index).Found then
               Fail
                 (Names (Index).Owner (1 .. Names (Index).Owner_Last)
                  & " asks for "
                  & Names (Index).Text (1 .. Names (Index).Last)
                  & ", which nothing attaches");
            end if;
         end loop;
      end;

      --  Nothing large is committed here.
      --
      --  No mandatory test may need a large model, and no model may be
      --  redistributed from this repository. Both hold today because the
      --  fixtures are generated and tiny, and both would stop holding the
      --  moment somebody committed a real one to make a test easier. The
      --  largest thing here is a test source; a small real model is a
      --  hundred times that.
      declare
         use type Dirs.File_Kind;
         use type Dirs.File_Size;

         Limit : constant Dirs.File_Size := 1_048_576;

         procedure Weigh (Directory : String);

         procedure Weigh (Directory : String) is
            Search : Dirs.Search_Type;
            Item   : Dirs.Directory_Entry_Type;
         begin
            if not Files.Directory_Exists (Path (Directory)) then
               return;
            end if;

            Dirs.Start_Search (Search, Path (Directory), "");

            while Dirs.More_Entries (Search) loop
               Dirs.Get_Next_Entry (Search, Item);

               declare
                  Simple : constant String := Dirs.Simple_Name (Item);
                  Child  : constant String :=
                    Hostkit.Fs.Join (Directory, Simple);
               begin
                  if Simple = "." or else Simple = ".." then
                     null;

                  elsif Dirs.Kind (Item) = Dirs.Directory then
                     --  What a build or a checkout leaves is not committed.
                     if Simple /= ".git"
                       and then Simple /= "obj"
                       and then Simple /= "bin"
                       and then Simple /= "alire"
                     then
                        Weigh (Child);
                     end if;

                  elsif Dirs.Kind (Item) = Dirs.Ordinary_File then
                     --  One check per file, so the total this run reports
                     --  moves with what the tree holds: a generated config,
                     --  an editor's settings, a fixture the suite wrote. A
                     --  clone of this repository counts four fewer than the
                     --  tree it was cloned from, and that is why. The number
                     --  is a tally, not a fingerprint; the floor at the end
                     --  of this run is what holds it to meaning something.
                     Result.Performed := Result.Performed + 1;

                     if Dirs.Size (Item) > Limit then
                        Fail
                          (Child & " is larger than this repository accepts");
                     end if;

                     --  And nothing written in another language. Only
                     --  implementation files: the build system generates a
                     --  C header for its own configuration, which compiles
                     --  nothing here.
                     declare
                        Name : constant String := T.To_Lower (Simple);

                        function Ends_With (Suffix : String) return Boolean is
                          (Name'Length > Suffix'Length
                             and then Name (Name'Last - Suffix'Length + 1
                                            .. Name'Last) = Suffix);
                     begin
                        if Ends_With (".c") or else Ends_With (".cc")
                          or else Ends_With (".cpp") or else Ends_With (".cxx")
                          or else Ends_With (".s") or else Ends_With (".asm")
                        then
                           Fail (Child & " is not Ada");
                        end if;
                     end;
                  end if;
               end;
            end loop;

            Dirs.End_Search (Search);
         end Weigh;
      begin
         Weigh (".");
      end;

      --  Reading a model must not lead to reading anything else.
      --
      --  A file says what its metadata says, and a chat template is a small
      --  program written by whoever produced the model. Both are interpreted
      --  here, and neither may reach the filesystem while it is: a template
      --  that could name a file to include, or a metadata value that could
      --  name one to load, turns a model into something that reads what it
      --  likes from the machine that opened it.
      --
      --  So the units that interpret what a container holds may not reach a
      --  file, a stream, a directory, the environment or the command line.
      --  Reading the container itself is the reader's work, and the reader
      --  is not on this list.
      declare
         procedure Reject_Reach (Relative, Token : String) is
         begin
            if Holds (Contents (Relative), Token) then
               Fail (Relative & " reaches a file while reading a model: "
                     & Token);
            end if;
         end Reject_Reach;

         procedure Interprets_Only (Simple : String) is
            Relative : constant String :=
              Hostkit.Fs.Join ("src/library", Simple);
         begin
            Result.Performed := Result.Performed + 1;

            if not Files.File_Exists (Path (Relative)) then
               Fail (Relative & " is named by this check but is not there");
               return;
            end if;

            Reject_Reach (Relative, "with Ada.Text_IO");
            Reject_Reach (Relative, "with Ada.Streams");
            Reject_Reach (Relative, "with Ada.Directories");
            Reject_Reach (Relative, "with Ada.Command_Line");
            Reject_Reach (Relative, "with Ada.Environment_Variables");
            Reject_Reach (Relative, "with Model_Runner.Byte_Sources");
            Reject_Reach (Relative, "with Model_Runner.Platform");
            Reject_Reach (Relative, "with Hostkit");
         end Interprets_Only;
      begin
         Interprets_Only ("model_runner-templates.adb");
         Interprets_Only ("model_runner-conversation.adb");
         Interprets_Only ("model_runner-tokenizer.adb");
         Interprets_Only ("model_runner-gguf-containers.adb");
         Interprets_Only ("model_runner-stops.adb");
         Interprets_Only ("model_runner-sampling.adb");
         Interprets_Only ("model_runner-llama.adb");
         Interprets_Only ("model_runner-quantization.adb");
         Interprets_Only ("model_runner-tensors.adb");
         Interprets_Only ("model_runner-kernels.adb");
      end;

      --  The environment surface is what the README says it is.
      --
      --  Every variable this program reads is an input somebody else can
      --  set, and the README lists them so a reader can see the whole of
      --  that surface. A variable read but not listed is a way in that
      --  nobody was told about -- which is how the locale variables sat
      --  unlisted here until this check went looking.
      --
      --  Only two files may read the environment at all. That is what keeps
      --  the surface small enough to list: a read anywhere else has to be
      --  moved or the rule changed deliberately.
      declare
         Readme : constant String := Contents ("README.md");

         --  Names appear as Environment_Value ("X") or Environment_Exists
         --  ("X"). The declarations of those functions take a parameter
         --  rather than a literal, so requiring the quote is what tells a
         --  call from the thing being called.
         procedure Visit_Environment (Relative : String) is
            Text : constant String := Contents (Relative);
            Lower : constant String := T.To_Lower (Relative);

            Allowed : constant Boolean :=
              Holds (Lower, "model_runner-platform.adb")
                or else Holds (Lower, "model_runner-cli-driver.adb");

            procedure Scan_For (Token : String) is
               Index : Natural := Text'First;
            begin
               if Text'Length < Token'Length then
                  return;
               end if;

               while Index <= Text'Last - Token'Length + 1 loop
                  if Text (Index .. Index + Token'Length - 1) = Token then
                     if not Allowed then
                        Fail (Relative & " reads the environment");
                     end if;

                     declare
                        First : constant Natural := Index + Token'Length;
                        Close : Natural := First;
                     begin
                        while Close <= Text'Last
                          and then Text (Close) /= '"'
                        loop
                           Close := Close + 1;
                        end loop;

                        if Close <= Text'Last and then Close > First then
                           declare
                              Named : constant String :=
                                Text (First .. Close - 1);
                           begin
                              if not Holds (Readme, "`" & Named & "`") then
                                 Fail
                                   (Relative & " reads " & Named
                                    & ", which the README does not list");
                              end if;
                           end;
                        end if;
                     end;
                  end if;

                  Index := Index + 1;
               end loop;
            end Scan_For;
         begin
            Result.Performed := Result.Performed + 1;
            Scan_For ("Environment_Value (""");
            Scan_For ("Environment_Exists (""");
         end Visit_Environment;

         procedure Scan_Environment is new For_Each_Source (Visit_Environment);
      begin
         Scan_Environment ("src");
      end;

      --  The published performance figures still describe this code.
      --
      --  They cannot be checked by value: they move half a per cent between
      --  runs on this machine and further on another, so an assertion about
      --  the number would fail everywhere it was not taken. What can be
      --  checked is whether the sources behind them have changed since, which
      --  is the only way they have ever gone wrong here -- twice, by two to
      --  four times, because a kernel changed and nobody re-measured.
      --
      --  A mismatch is not a defect in the code. It is a question that has to
      --  be answered before release: re-measure, or say why the change cannot
      --  have moved the number.

      --  The same question about a shader. A compiled shader is committed as
      --  Ada beside the source it came from, and nothing in a build recompiles
      --  it: a shader edited and not recompiled would go on running the old
      --  words with the new source sitting beside them, which is the kind of
      --  wrong that survives every test because every test runs the words.
      declare
         Found : Boolean;

         Digest : constant Interfaces.Unsigned_64 :=
           Shader_Generation.Source_Digest
             (Root & "/src/shaders/row_product.comp", Found);
      begin
         Result.Performed := Result.Performed + 1;

         if not Found then
            Fail ("src/shaders/row_product.comp is missing, and the words "
                  & "compiled from it are committed");
         elsif Digest /= Model_Runner.Shaders.Row_Product_Digest then
            Fail ("src/shaders/row_product.comp has changed since it was "
                  & "compiled; compile it and run 'tests shader "
                  & "src/shaders/row_product.comp OUT.spv' again");
         end if;

         --  That source is compiled twice as well, the second with SINGLE,
         --  and the narrow words carry a digest of their own. Read for the
         --  same reason as the matrix product's pair: a regeneration that
         --  named the file once leaves the other half behind.
         Result.Performed := Result.Performed + 1;

         if Found
           and then Digest /= Model_Runner.Shaders.Row_Single_Digest
         then
            Fail ("the second compilation of src/shaders/row_product.comp "
                  & "is older than the source; compile it twice, the second "
                  & "with -DSINGLE to row_single.spv, and run 'tests shader' "
                  & "again with every shader named");
         end if;
      end;

      --  And the second shader, asked the same way. Every shader the engine
      --  carries needs its own question here: one asked and one not is a
      --  shader that may go stale unwatched, which is the whole of what this
      --  check exists to prevent.
      declare
         Found : Boolean;

         Digest : constant Interfaces.Unsigned_64 :=
           Shader_Generation.Source_Digest
             (Root & "/src/shaders/combine.comp", Found);
      begin
         Result.Performed := Result.Performed + 1;

         if not Found then
            Fail ("src/shaders/combine.comp is missing, and the words "
                  & "compiled from it are committed");
         elsif Digest /= Model_Runner.Shaders.Combine_Digest then
            Fail ("src/shaders/combine.comp has changed since it was "
                  & "compiled; compile it and run 'tests shader' again with "
                  & "every shader named");
         end if;
      end;

      --  And the third, asked the same way.
      declare
         Found : Boolean;

         Digest : constant Interfaces.Unsigned_64 :=
           Shader_Generation.Source_Digest
             (Root & "/src/shaders/norm.comp", Found);
      begin
         Result.Performed := Result.Performed + 1;

         if not Found then
            Fail ("src/shaders/norm.comp is missing, and the words "
                  & "compiled from it are committed");
         elsif Digest /= Model_Runner.Shaders.Norm_Digest then
            Fail ("src/shaders/norm.comp has changed since it was "
                  & "compiled; compile it and run 'tests shader' again with "
                  & "every shader named");
         end if;
      end;

      --  And the fourth, asked the same way.
      declare
         Found : Boolean;

         Digest : constant Interfaces.Unsigned_64 :=
           Shader_Generation.Source_Digest
             (Root & "/src/shaders/rotate.comp", Found);
      begin
         Result.Performed := Result.Performed + 1;

         if not Found then
            Fail ("src/shaders/rotate.comp is missing, and the words "
                  & "compiled from it are committed");
         elsif Digest /= Model_Runner.Shaders.Rotate_Digest then
            Fail ("src/shaders/rotate.comp has changed since it was "
                  & "compiled; compile it and run 'tests shader' again with "
                  & "every shader named");
         end if;
      end;

      --  And the fifth, asked the same way.
      declare
         Found : Boolean;

         Digest : constant Interfaces.Unsigned_64 :=
           Shader_Generation.Source_Digest
             (Root & "/src/shaders/place.comp", Found);
      begin
         Result.Performed := Result.Performed + 1;

         if not Found then
            Fail ("src/shaders/place.comp is missing, and the words "
                  & "compiled from it are committed");
         elsif Digest /= Model_Runner.Shaders.Place_Digest then
            Fail ("src/shaders/place.comp has changed since it was "
                  & "compiled; compile it and run 'tests shader' again with "
                  & "every shader named");
         end if;
      end;

      --  And the sixth, asked the same way.
      declare
         Found : Boolean;

         Digest : constant Interfaces.Unsigned_64 :=
           Shader_Generation.Source_Digest
             (Root & "/src/shaders/attention.comp", Found);
      begin
         Result.Performed := Result.Performed + 1;

         if not Found then
            Fail ("src/shaders/attention.comp is missing, and the words "
                  & "compiled from it are committed");
         elsif Digest /= Model_Runner.Shaders.Attention_Digest then
            Fail ("src/shaders/attention.comp has changed since it was "
                  & "compiled; compile it and run 'tests shader' again with "
                  & "every shader named");
         end if;

         --  That source is compiled twice too, the second with SUBGROUPS,
         --  and the subgroup words carry a digest of their own. Read for
         --  the same reason as the other two pairs.
         Result.Performed := Result.Performed + 1;

         if Found
           and then Digest
                      /= Model_Runner.Shaders.Attention_Subgroups_Digest
         then
            Fail ("the second compilation of src/shaders/attention.comp is "
                  & "older than the source; compile it twice, the second "
                  & "with --target-env vulkan1.1 -DSUBGROUPS -DWIDE to "
                  & "attention_subgroups.spv, and run 'tests shader' again "
                  & "with every shader named");
         end if;

         --  The tiled compilation's block width is stated twice: once in
         --  the shader, which decides how many queries a workgroup answers,
         --  and once in the engine, which decides how many workgroups are
         --  asked for. Two hand-kept copies of a number drift, and this one
         --  drifted inside an hour of being written -- a careless edit set
         --  the shader's to four where the engine still said one, and every
         --  test passed because the suite's batches are shorter than a
         --  block. Read the shader's and require them to agree.
         declare
            Text : constant String :=
              Contents ("src/shaders/attention.comp");

            Marker : constant String := "#ifdef QUERY_TILE";
            Named  : constant String := "const uint QUERIES = ";

            Said : Natural := 0;
            At_If : Natural := 0;
         begin
            Result.Performed := Result.Performed + 1;

            for Index in Text'First
                         .. Text'Last - Marker'Length + 1
            loop
               if Text (Index .. Index + Marker'Length - 1) = Marker then
                  At_If := Index;
                  exit;
               end if;
            end loop;

            if At_If = 0 then
               Fail ("src/shaders/attention.comp no longer names "
                     & "QUERY_TILE, and the engine still asks for blocks "
                     & "of" & Natural'Image
                       (Model_Runner.Platform.Device.Products.Query_Block));
            else
               for Index in At_If .. Text'Last - Named'Length + 1 loop
                  if Text (Index .. Index + Named'Length - 1) = Named then
                     for Digit in Index + Named'Length .. Text'Last loop
                        exit when Text (Digit) not in '0' .. '9';
                        Said := Said * 10
                                + Character'Pos (Text (Digit))
                                - Character'Pos ('0');
                     end loop;
                     exit;
                  end if;
               end loop;

               if Said
                  /= Model_Runner.Platform.Device.Products.Query_Block
               then
                  Fail ("src/shaders/attention.comp answers"
                        & Natural'Image (Said) & " queries a workgroup and "
                        & "the engine dispatches for blocks of"
                        & Natural'Image
                          (Model_Runner.Platform.Device.Products.Query_Block)
                        & "; a batch longer than a block would be answered "
                        & "in part");
               end if;
            end if;
         end;

         --  And the matrix tile, stated twice for the same reason and never
         --  checked until it had shipped wrong.
         --
         --  matrix_product.comp said a tile of sixty-four vectors and the
         --  engine dispatched for a hundred and twenty-eight, so a workgroup
         --  answered the first sixty-four of every tile and nothing answered
         --  the rest. Every prompt of more than sixty-four tokens came back
         --  as noise on the device. Nothing caught it: the sweep's longest
         --  sequence is eight tokens, so no comparison it makes ever crosses
         --  a tile at all, and a speed run reports a digest nobody compares.
         --
         --  Read both numbers out of both files. The engine's are in its
         --  body rather than its specification, so they are read as text
         --  like the shader's -- which is worse than naming them, and much
         --  better than not looking.
         declare
            Shader : constant String :=
              Contents ("src/shaders/matrix_product.comp");
            Engine : constant String :=
              Contents
                ("src/library/model_runner-platform-device-products.adb");

            function Number_After
              (Text : String; Marker : String) return Natural;

            function Number_After
              (Text : String; Marker : String) return Natural
            is
               Found : Natural := 0;
            begin
               if Marker'Length > Text'Length then
                  return 0;
               end if;

               for Index in Text'First .. Text'Last - Marker'Length + 1 loop
                  if Text (Index .. Index + Marker'Length - 1) = Marker then
                     for Digit in Index + Marker'Length .. Text'Last loop
                        exit when Text (Digit) not in '0' .. '9';
                        Found := Found * 10
                                 + Character'Pos (Text (Digit))
                                 - Character'Pos ('0');
                     end loop;
                     return Found;
                  end if;
               end loop;

               return 0;
            end Number_After;

            Rows_Said : constant Natural :=
              Number_After (Shader, "const uint TILE_R = ");
            Vecs_Said : constant Natural :=
              Number_After (Shader, "const uint TILE_V = ");
            Rows_Asked : constant Natural :=
              Number_After (Engine, "Tile_Rows    : constant := ");
            Vecs_Asked : constant Natural :=
              Number_After (Engine, "Tile_Vectors : constant := ");

            --  And the step, which nothing outside the shader reads and
            --  which the staging is written to by hand.
            Step_Said : constant Natural :=
              Number_After (Shader, "const uint KCH    = ");
         begin
            Result.Performed := Result.Performed + 1;

            if Rows_Said = 0 or else Vecs_Said = 0
              or else Rows_Asked = 0 or else Vecs_Asked = 0
            then
               Fail ("one of the matrix tile's four numbers could not be "
                     & "read: the shader states TILE_R and TILE_V and the "
                     & "engine states Tile_Rows and Tile_Vectors, and this "
                     & "check reads all four as text");
            elsif Rows_Said /= Rows_Asked or else Vecs_Said /= Vecs_Asked then
               Fail ("src/shaders/matrix_product.comp answers a tile of"
                     & Natural'Image (Rows_Said) & " rows by"
                     & Natural'Image (Vecs_Said) & " vectors and the engine "
                     & "dispatches for" & Natural'Image (Rows_Asked) & " by"
                     & Natural'Image (Vecs_Asked)
                     & "; whatever a workgroup does not reach is left "
                     & "uncomputed, which is noise and not an error");
            end if;

            --  And the shape the staging is written for, which is a
            --  separate question from whether the two files agree.
            --
            --  Sixty-four invocations decode thirty-two rows of a
            --  thirty-two column step, half a row each, and the invocation
            --  number is cut in two to say which row and which half. Move
            --  TILE_R or KCH and that mapping is wrong: the kernel still
            --  compiles, the engine still dispatches it, and it computes
            --  from the wrong place. A sweep of six shapes found exactly
            --  that -- three of them produced a kernel that ran and
            --  answered nothing, and every one of the three moved one of
            --  these two.
            --
            --  So they are pinned here rather than left as a trap. The
            --  staging was rewritten to deal its work round the workgroup,
            --  which makes both of them free; it cost one and a half per
            --  cent of a device prompt and the sweep it made possible found
            --  no shape better than this one, so what is kept is this check
            --  and the measurement in docs/measured-figures.txt.
            Result.Performed := Result.Performed + 1;

            if Rows_Said /= 32 or else Step_Said /= 32 then
               Fail ("src/shaders/matrix_product.comp states TILE_R"
                     & Natural'Image (Rows_Said) & " and KCH"
                     & Natural'Image (Step_Said)
                     & "; its staging loop is written by hand for thirty-two"
                     & " of each and computes from the wrong place at any"
                     & " other shape, without failing to compile or to run");
            end if;
         end;

         --  And the third, with QUERY_TILE beside it.
         Result.Performed := Result.Performed + 1;

         if Found
           and then Digest /= Model_Runner.Shaders.Attention_Tiled_Digest
         then
            Fail ("the third compilation of src/shaders/attention.comp is "
                  & "older than the source; compile it with --target-env "
                  & "vulkan1.1 -DSUBGROUPS -DQUERY_TILE to "
                  & "attention_tiled.spv, and run 'tests shader' again "
                  & "with every shader named");
         end if;
      end;

      --  And the fourth, which only some devices run: the matrix product.
      --  A shader nothing on this host can enter is still a shader that
      --  must not go stale, and this is the only thing that would notice.
      declare
         Found : Boolean;

         Digest : constant Interfaces.Unsigned_64 :=
           Shader_Generation.Source_Digest
             (Root & "/src/shaders/matrix_product.comp", Found);
      begin
         Result.Performed := Result.Performed + 1;

         if not Found then
            Fail ("src/shaders/matrix_product.comp is missing, and the "
                  & "words compiled from it are committed");
         elsif Digest /= Model_Runner.Shaders.Matrix_Product_Digest then
            Fail ("src/shaders/matrix_product.comp has changed since it "
                  & "was compiled; compile it with --target-env vulkan1.3 "
                  & "and run 'tests shader' again with every shader named");
         end if;

         --  That source is compiled twice, once with MORE_FORMATS, and each
         --  compilation carries a digest of the source it came from. The
         --  test above reads one of them; this reads the other, because a
         --  regeneration that named the file once would leave the second
         --  set of words behind without anything noticing.
         Result.Performed := Result.Performed + 1;

         if Found
           and then Digest /= Model_Runner.Shaders.Matrix_Extra_Digest
         then
            Fail ("the second compilation of src/shaders/matrix_product.comp"
                  & " is older than the source; compile it twice, the second"
                  & " with -DMORE_FORMATS to matrix_extra.spv, and run "
                  & "'tests shader' again with every shader named");
         end if;
      end;

      --  And attention through the same instruction, which is a shader of
      --  its own rather than another compilation of attention.comp: the
      --  scores and the weighted values are matrix products there and
      --  loops here, and only the softmax between them reads the same.
      declare
         Found : Boolean;

         Digest : constant Interfaces.Unsigned_64 :=
           Shader_Generation.Source_Digest
             (Root & "/src/shaders/attention_matrix.comp", Found);
      begin
         Result.Performed := Result.Performed + 1;

         if not Found then
            Fail ("src/shaders/attention_matrix.comp is missing, and the "
                  & "words compiled from it are committed");
         elsif Digest /= Model_Runner.Shaders.Attention_Matrix_Digest then
            Fail ("src/shaders/attention_matrix.comp has changed since it "
                  & "was compiled; compile it with --target-env vulkan1.3 "
                  & "and run 'tests shader' again with every shader named");
         end if;
      end;

      --  And the fifth, which goes with it.
      declare
         Found : Boolean;

         Digest : constant Interfaces.Unsigned_64 :=
           Shader_Generation.Source_Digest
             (Root & "/src/shaders/half_batch.comp", Found);
      begin
         Result.Performed := Result.Performed + 1;

         if not Found then
            Fail ("src/shaders/half_batch.comp is missing, and the words "
                  & "compiled from it are committed");
         elsif Digest /= Model_Runner.Shaders.Half_Batch_Digest then
            Fail ("src/shaders/half_batch.comp has changed since it was "
                  & "compiled; compile it and run 'tests shader' again with "
                  & "every shader named");
         end if;
      end;
      --  Every figure the device table publishes has to appear in the
      --  record that says how it was taken.
      --
      --  The fingerprints above catch a source that moved without its
      --  figures being re-measured. They cannot catch the other direction:
      --  a number edited into the README and not into the record, or
      --  re-measured into the record and not into the README. Both happened
      --  while this table was being rewritten, and neither would have been
      --  noticed by anything here.
      --
      --  Only the device table, and only the seconds in it. A rule that
      --  tried to cover every number in the README would either miss most
      --  of them or object to the ones that are counts and ratios, and a
      --  check that cries wolf is a check that gets a wolf.
      declare
         Table  : constant String := Contents ("README.md");
         Record_Of : constant String := Contents ("docs/measured-figures.txt");

         Heading : constant String := "### The device backend";

         Looked : Natural := 0;
         Missed : Natural := 0;

         At_Heading : Natural := 0;
      begin
         if Table'Length > 0 and then Record_Of'Length > 0 then
            for Index in Table'First
                         .. Table'Last - Heading'Length + 1
            loop
               if Table (Index .. Index + Heading'Length - 1) = Heading then
                  At_Heading := Index;
                  exit;
               end if;
            end loop;

            if At_Heading = 0 then
               Fail ("README.md has no ""### The device backend"" heading, "
                     & "so the figures under it cannot be checked against "
                     & "the record of how they were taken");
            else
               declare
                  --  The table is the run of lines beginning with a bar
                  --  that follows the heading. Stopping at the first line
                  --  after it that is not one keeps this to the table
                  --  rather than to the prose under it, which quotes
                  --  figures it is explaining and quotes withdrawn ones on
                  --  purpose.
                  At_Line : Natural := At_Heading;
                  Started : Boolean := False;
                  Done    : Boolean := False;
               begin
                  while not Done and then At_Line <= Table'Last loop
                     declare
                        Ends : Natural := At_Line;
                     begin
                        while Ends <= Table'Last
                          and then Table (Ends) /= Character'Val (10)
                        loop
                           Ends := Ends + 1;
                        end loop;

                        declare
                           Line : constant String :=
                             Table (At_Line .. Natural'Min (Ends - 1,
                                                            Table'Last));
                        begin
                           if Line'Length > 0
                             and then Line (Line'First) = '|'
                           then
                              Started := True;

                              --  Each run of digits with a point in it,
                              --  followed by " s", is a figure.
                              for At_Digit in Line'Range loop
                                 if Line (At_Digit) in '0' .. '9'
                                   and then (At_Digit = Line'First
                                             or else Line (At_Digit - 1)
                                                       not in '0' .. '9'
                                                              | '.')
                                 then
                                    declare
                                       Stop : Natural := At_Digit;
                                    begin
                                       while Stop < Line'Last
                                         and then (Line (Stop + 1)
                                                     in '0' .. '9' | '.')
                                       loop
                                          Stop := Stop + 1;
                                       end loop;

                                       if Stop + 2 <= Line'Last
                                         and then Line (Stop + 1 .. Stop + 2)
                                                    = " s"
                                       then
                                          declare
                                             Figure : constant String :=
                                               Line (At_Digit .. Stop);
                                             Found : Boolean := False;
                                          begin
                                             Looked := Looked + 1;

                                             for Where in Record_Of'First
                                                          .. Record_Of'Last
                                                             - Figure'Length
                                                             + 1
                                             loop
                                                if Record_Of
                                                     (Where .. Where
                                                      + Figure'Length - 1)
                                                   = Figure
                                                then
                                                   Found := True;
                                                   exit;
                                                end if;
                                             end loop;

                                             if not Found then
                                                Missed := Missed + 1;
                                                Fail
                                                  ("README.md publishes "
                                                   & Figure & " s in the "
                                                   & "device table and "
                                                   & "docs/measured-figures"
                                                   & ".txt does not mention "
                                                   & "it, so nothing says "
                                                   & "how it was taken");
                                             end if;
                                          end;
                                       end if;
                                    end;
                                 end if;
                              end loop;
                           elsif Started then
                              Done := True;
                           end if;
                        end;

                        At_Line := Ends + 1;
                     end;
                  end loop;
               end;

               if Looked = 0 then
                  Fail ("no figures were found in README.md's device table, "
                        & "so whether each is recorded was not asked");
               end if;

               Result.Performed := Result.Performed + Looked;
            end if;
         end if;
      end;

      declare
         Record_Path : constant String := "docs/measured-figures.txt";
         Listing     : constant String := Contents (Record_Path);

         --  The Nth space-separated word of a line, or the empty string.
         function Word (Line : String; Wanted : Positive) return String is
            Seen  : Natural := 0;
            Start : Natural := 0;
         begin
            for Index in Line'Range loop
               if Line (Index) /= ' ' then
                  if Start = 0 then
                     Start := Index;
                     Seen := Seen + 1;
                  end if;
                  if Seen = Wanted and then
                    (Index = Line'Last or else Line (Index + 1) = ' ')
                  then
                     return Line (Start .. Index);
                  end if;
               else
                  Start := 0;
               end if;
            end loop;
            return "";
         end Word;

         From : Positive := (if Listing'Length = 0 then 1 else Listing'First);

         --  The "# covers:" line before a group says which published figures
         --  it stands for. Without it the check tells a reader that something
         --  changed and leaves them to guess what to measure again.
         Marker  : constant String := "# covers:";
         Covers  : String (1 .. 400) := [others => ' '];
         Covered : Natural := 0;

         --  The "# load:" line before a group says what the machine was
         --  doing when its figures were taken. A timing is a fact about a
         --  machine at a moment and the moment is half of it: the processor
         --  side of the comparisons here has moved by forty per cent
         --  between otherwise identical runs. A figure that carries the
         --  load it was taken under can be compared with another; one that
         --  does not has to be believed.
         --
         --  The tools print it and this is what makes them: every group has
         --  to say, so a figure taken before the tools reported a load has
         --  to be taken again rather than left with an empty provenance.
         Load_Marker : constant String := "# load:";
         Load_Said   : Boolean := False;

         --  A group may say its load is unknown, and some have to: figures
         --  taken before the tools printed one cannot be given a load now
         --  without inventing it. What is refused is silence. What is
         --  reported is how many are still unknown, so the number is
         --  visible and can only go down -- a figure retaken is a figure
         --  that arrives with its conditions.
         Load_Unknown : Boolean := False;
         Unknown_Loads : Natural := 0;
      begin
         Result.Performed := Result.Performed + 1;

         if Listing'Length = 0 then
            Fail (Record_Path & " is missing, so nothing records what the "
                  & "published figures were measured against");
         else
            while From <= Listing'Last loop
               declare
                  Stop : Natural := From;
               begin
                  while Stop <= Listing'Last
                    and then Listing (Stop) /= Character'Val (10)
                  loop
                     Stop := Stop + 1;
                  end loop;

                  declare
                     Line : constant String := Listing (From .. Stop - 1);
                  begin
                     if Line'Length >= Marker'Length
                       and then Line (Line'First .. Line'First
                                      + Marker'Length - 1) = Marker
                     then
                        declare
                           Rest  : constant String :=
                             Line (Line'First + Marker'Length .. Line'Last);
                           Begins : Natural := Rest'First;
                        begin
                           while Begins <= Rest'Last
                             and then Rest (Begins) = ' '
                           loop
                              Begins := Begins + 1;
                           end loop;

                           declare
                              Said : constant String :=
                                Rest (Begins .. Rest'Last);
                              Room : constant Natural :=
                                Natural'Min (Said'Length, Covers'Length);
                           begin
                              Covers (1 .. Room) :=
                                Said (Said'First .. Said'First + Room - 1);
                              Covered := Room;
                           end;
                        end;
                     end if;

                     if Line'Length >= Load_Marker'Length
                       and then Line (Line'First .. Line'First
                                      + Load_Marker'Length - 1) = Load_Marker
                     then
                        Load_Said := True;
                        Load_Unknown :=
                          Project_Tools.Text.Contains (Line, "unknown");
                     end if;

                     if Line'Length > 0
                       and then Word (Line, 1)'Length > 0
                       and then Word (Line, 1) (Word (Line, 1)'First) /= '#'
                     then
                        declare
                           Name  : constant String := Word (Line, 1);
                           Known : constant String := Word (Line, 2);
                           Sum   : Interfaces.Unsigned_64 :=
                             16#CBF29CE484222325#;
                           Whole : Boolean := Known'Length > 0;
                           Which : Positive := 3;
                        begin
                           loop
                              declare
                                 Source : constant String :=
                                   Word (Line, Which);
                              begin
                                 exit when Source'Length = 0;
                                 declare
                                    Text_Of : constant String :=
                                      Contents (Source);
                                 begin
                                    if Text_Of'Length = 0 then
                                       Fail (Record_Path & " names " & Source
                                             & ", which is not there");
                                       Whole := False;
                                    else
                                       for Letter of Text_Of loop
                                          Sum :=
                                            (Sum xor Interfaces.Unsigned_64
                                               (Character'Pos (Letter)))
                                            * 16#100000001B3#;
                                       end loop;
                                    end if;
                                 end;
                              end;
                              Which := Which + 1;
                           end loop;

                           Result.Performed := Result.Performed + 1;
                           if not Load_Said then
                              Fail (Record_Path & " records " & Name
                                    & " without a load line, so what "
                                    & "the machine was doing when those "
                                    & "figures were taken is not written "
                                    & "down anywhere");
                           end if;
                           if Load_Said and then Load_Unknown then
                              Unknown_Loads := Unknown_Loads + 1;
                           end if;
                           Load_Said := False;
                           Load_Unknown := False;

                           if Whole and then Which = 3 then
                              Fail (Record_Path & " records " & Name
                                    & " without naming a source");
                           elsif Whole and then Hex (Sum) /= Known then
                              Fail ("the sources behind the published "
                                    & Name & " figures have changed since "
                                    & "they were measured; re-measure "
                                    & (if Covered > 0
                                       then Covers (1 .. Covered)
                                       else "them")
                                    & ", then record " & Hex (Sum) & " in "
                                    & Record_Path);
                           end if;
                           Covered := 0;
                        end;
                     end if;
                  end;

                  From := Stop + 1;
               end;
            end loop;

            if Unknown_Loads > 0 then
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "  note:" & Natural'Image (Unknown_Loads)
                  & " figure groups do not record the load they were taken "
                  & "under, because they were taken before the tools "
                  & "reported one; retaking a group is what removes it from "
                  & "that count");
            end if;
         end if;
      end;

      --  The tally is held to a floor.
      --
      --  This number is quoted in every report of a run, and nothing pinned
      --  it: a check that stopped running, a scan that stopped finding, or a
      --  tree that yielded fewer files would all have read as a clean run.
      --  Two other floors exist here for exactly that -- the sources the walk
      --  must reach, and the tests the suite must register -- and both were
      --  written after something went quietly missing.
      --
      --  A floor rather than a figure, because the total legitimately moves:
      --  one of these checks weighs every file in the tree, so a generated
      --  config or a fixture the suite wrote changes it by a few either way.
      --  Well under the count so that ordinary work is not an event, and far
      --  The changelog keeps up with the library.
      --
      --  It says on its first line that all notable changes are recorded in
      --  it, and nothing held that. Eleven commits went by unrecorded, among
      --  them a denial of service anyone could send, a tokenizer defect that
      --  made every SentencePiece model read its own template's end marker
      --  as a run of bytes, and two silent losses on the byte-pair road. A
      --  reader deciding whether to upgrade would have learned none of it,
      --  and the only thing checked about the file was that it exists.
      --
      --  What is asked is that the newest commit touching the program is an
      --  ancestor of -- or the same as -- the newest commit touching
      --  CHANGELOG.md. Committing both together satisfies it, since a commit
      --  is its own ancestor, so the rule in practice is that a change and
      --  its entry arrive together.
      --
      --  Ancestry rather than dates. The first version compared committer
      --  timestamps, which are metadata a rebase rewrites and a skewed clock
      --  gets wrong, and two commits made in the same second compared equal
      --  and passed. Git can answer the question that was meant, and
      --  merge-base is how it is asked.
      --
      --  The program is the library, the messages it prints and the
      --  checklist that decides whether a release goes out. It watched src
      --  alone at first, which left every user-visible string uncovered: a
      --  reworded diagnostic is a notable change by any reading.
      --
      --  Of committed history rather than of the working tree: an entry
      --  written and not committed has not been published. Without git the
      --  question cannot be asked, and saying so is better than passing.
      declare
         Git : constant String :=
           Project_Tools.Processes.Locate_Command ("git");

         Tree : constant String := Ada.Directories.Full_Name (Root);

         procedure Add
           (Args : in out Project_Tools.Processes.Argument_Vectors.Vector;
            Word : String) is
         begin
            Project_Tools.Processes.Argument_Vectors.Append
              (Args, Ada.Strings.Unbounded.To_Unbounded_String (Word));
         end Add;

         --  The commit that last touched a path, or nothing when the tree
         --  has no history -- which a source archive has not.
         function Newest (Path : String) return String is
            Args : Project_Tools.Processes.Argument_Vectors.Vector;

            --  Passed even though it is not read: Command_Output
            --  dereferences it without asking whether it is there.
            Status : aliased Integer := 0;
         begin
            Add (Args, "-C");
            Add (Args, Tree);
            Add (Args, "log");
            Add (Args, "-1");
            Add (Args, "--format=%H");
            Add (Args, "--");
            Add (Args, Path);

            return T.Trim
              (Project_Tools.Processes.Command_Output
                 (Command   => Git,
                  Arguments => Args,
                  Status    => Status'Access));
         end Newest;

         --  Whether Earlier is an ancestor of Later, or is Later itself.
         function Comes_Before (Earlier, Later : String) return Boolean is
            Args : Project_Tools.Processes.Argument_Vectors.Vector;
         begin
            Add (Args, "-C");
            Add (Args, Tree);
            Add (Args, "merge-base");
            Add (Args, "--is-ancestor");
            Add (Args, Earlier);
            Add (Args, Later);

            return Project_Tools.Processes.Run_Status
                     (Label   => "changelog ancestry",
                      Dir     => Tree,
                      Program => Git,
                      Args    => Args,
                      Quiet   => True) = 0;
         end Comes_Before;
      begin
         Result.Performed := Result.Performed + 1;

         if Git = "" then
            Fail ("no git on the path, so whether the changelog keeps up "
                  & "with the library could not be asked");
         else
            declare
               Library : constant String := Newest ("src");
               Text    : constant String := Newest ("resources");
               Gate    : constant String := Newest ("tools");
               Changes : constant String := Newest ("CHANGELOG.md");
            begin
               --  A tree with no history, which a source archive is, has
               --  nothing to compare and nothing wrong.
               if Changes /= ""
                 and then ((Library /= ""
                            and then not Comes_Before (Library, Changes))
                           or else (Text /= ""
                                    and then not Comes_Before (Text, Changes))
                           or else (Gate /= ""
                                    and then not Comes_Before (Gate, Changes)))
               then
                  Fail ("the library, its messages or the release gate has "
                        & "changed since the changelog last did; put the "
                        & "entry under [Unreleased] and commit it with the "
                        & "change it describes");
               end if;
            end;
         end if;
      end;

      --  Every public operation a test names, or a reason it names none.
      --
      --  Sixty-three of three hundred and eighty-two were named by no test
      --  and nothing recorded it, so an operation exercised through a
      --  caller, one that answers differently on every machine, and one
      --  that is simply untested read alike. Untested_Surface holds the
      --  ones that remain, and this holds it in both directions: an
      --  operation a test starts naming fails until it comes off, and one
      --  that stops being named fails until it goes on.
      --
      --  The names are not qualified, so this errs towards saying an
      --  operation is tested -- the same proxy the code registry uses, and
      --  said there too.
      declare
         Named : Natural := 0;
         Total : Natural := 0;

         --  Every test source in one string, so that asking whether a name
         --  appears is one search rather than a walk per operation.
         Tests : Ada.Strings.Unbounded.Unbounded_String;

         procedure Gather_Test (Relative : String) is
         begin
            --  Not the registry itself, which names every operation on it
            --  by construction and would report all of them as tested --
            --  which is what it did.
            if Relative = "tests/src/untested_surface.adb"
              or else Relative = "tests/src/untested_surface.ads"
            then
               return;
            end if;

            Ada.Strings.Unbounded.Append (Tests, Contents (Relative));
         end Gather_Test;

         procedure Gather_Tests is new For_Each_Source (Gather_Test);

         procedure Visit_Surface (Relative : String) is
            Text : constant String := Contents (Relative);
         begin
            if Relative'Length < 4
              or else Relative (Relative'Last - 3 .. Relative'Last) /= ".ads"
            then
               return;
            end if;

            for Index in Text'First .. Text'Last - 12 loop
               if (Index = Text'First
                   or else Text (Index - 1) = Character'Val (10))
                 and then Index + 12 <= Text'Last
                 and then (Text (Index .. Index + 12) = "   function  "
                           or else Text (Index .. Index + 12)
                                   = "   procedure ")
               then
                  declare
                     From : Natural := Index + 12;
                     Stop : Natural;
                  begin
                     while From <= Text'Last and then Text (From) = ' ' loop
                        From := From + 1;
                     end loop;

                     Stop := From;
                     while Stop <= Text'Last
                       and then (Text (Stop) in 'A' .. 'Z'
                                 or else Text (Stop) in 'a' .. 'z'
                                 or else Text (Stop) in '0' .. '9'
                                 or else Text (Stop) = '_')
                     loop
                        Stop := Stop + 1;
                     end loop;

                     if Stop > From then
                        declare
                           Name : constant String := Text (From .. Stop - 1);
                           Here : constant Boolean :=
                             Project_Tools.Text.Contains
                               (Ada.Strings.Unbounded.To_String (Tests),
                                Name);
                        begin
                           Total := Total + 1;
                           if Here then
                              Named := Named + 1;
                           end if;

                           Result.Performed := Result.Performed + 1;

                           if Here and then Untested_Surface.Is_Untested (Name)
                           then
                              Fail (Name & " is named by a test now; take it "
                                    & "off the untested list");
                           elsif not Here
                             and then not Untested_Surface.Is_Untested (Name)
                           then
                              Fail (Name & " in " & Relative & " is named by "
                                    & "no test; exercise it or put it on the "
                                    & "untested list with a reason");
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end loop;
         end Visit_Surface;

         procedure Scan_Surface is new For_Each_Source (Visit_Surface);
      begin
         Gather_Tests ("tests/src");
         Scan_Surface ("src/library");

         Result.Performed := Result.Performed + 1;
         if Total = 0 then
            Fail ("no public operations were found, so the check that each "
                  & "is named by a test matched nothing");
         end if;
      end;

      --  A shared-host directory says which hosts it is shared by.
      --
      --  src/platform/posix and tests/src/platform/posix are compiled for
      --  Linux and for macOS, and a number that is right for one is not
      --  thereby right for the other. That is not a hypothetical: the
      --  capture in the tests crate carried Linux's create-and-truncate
      --  flags -- O_CREAT is 8#100# there and 16#200# on macOS -- so on
      --  macOS it never truncated, and a short capture read back as the
      --  longer one before it. Three tests failed on that host and nowhere
      --  else, and the file's own name said posix, which reads as portable.
      --
      --  What is asked is that a source in one of those directories names
      --  both hosts. It cannot check a number against a header; it can make
      --  the author of the next one say which hosts they checked.
      declare
         procedure Visit_Shared (Relative : String) is
            Text : constant String := Contents (Relative);

            function Holds (Word : String) return Boolean is
            begin
               for Index in Text'First .. Text'Last - Word'Length + 1 loop
                  if Text (Index .. Index + Word'Length - 1) = Word then
                     return True;
                  end if;
               end loop;
               return False;
            end Holds;
         begin
            if Relative = "tests/src/checks.adb" then
               return;
            end if;

            Result.Performed := Result.Performed + 1;

            if not (Holds ("Linux") or else Holds ("linux")) then
               Fail (Relative & " is compiled for Linux and for macOS and "
                     & "names neither; say which hosts the values in it "
                     & "were checked against");
            elsif not (Holds ("macOS") or else Holds ("macos")) then
               Fail (Relative & " is compiled for Linux and for macOS and "
                     & "names only one of them");
            end if;
         end Visit_Shared;

         procedure Scan_Shared is new For_Each_Source (Visit_Shared);
      begin
         Scan_Shared ("src/platform/posix");
         Scan_Shared ("tests/src/platform/posix");
      end;

      --  No host call is bound straight from the tests crate.
      --
      --  Nothing reads a text file raw and then measures or matches it, and
      --  nothing names a built executable by one host's spelling.
      --
      --  These are the two shapes that took eight continuous-integration
      --  runs to find, and neither could have failed here: the checklist
      --  runs on one host, so a carriage return never arrives and .exe is
      --  never the name. Five of the eight were one of these two.
      --
      --  Read_Raw_File is the right call for bytes -- a model file, an
      --  archive -- and the wrong one for text that is about to be compared
      --  against something the program wrote, because a checkout gives back
      --  the host's line ending and the program writes its own. So the rule
      --  is not that the call is forbidden; it is that a file whose name
      --  says text goes through a reader that takes the returns off.
      declare
         procedure Visit_Reading (Relative : String) is
            Text : constant String := Contents (Relative);

            --  Whether a call reads something whose name says text.
            function Reads_Text (At_Index : Positive) return Boolean is
               Stop : Natural := At_Index;
            begin
               while Stop < Text'Last
                 and then Text (Stop) /= Character'Val (10)
               loop
                  Stop := Stop + 1;
               end loop;

               declare
                  Line : constant String := Text (At_Index .. Stop);
               begin
                  return Project_Tools.Text.Contains (Line, ".txt")
                    or else Project_Tools.Text.Contains (Line, ".md")
                    or else Project_Tools.Text.Contains (Line, "README");
               end;
            end Reads_Text;

            Marker : constant String := "Read_Raw_File (";
         begin
            --  Not this file: it names the call in the string it compares
            --  against, and reads through Contents itself.
            if Relative = "tests/src/checks.adb" then
               return;
            end if;

            for Index in Text'First .. Text'Last - Marker'Length loop
               if Text (Index .. Index + Marker'Length - 1) = Marker
                 and then Reads_Text (Index)
               then
                  Result.Performed := Result.Performed + 1;
                  Fail (Relative & " reads a text file with Read_Raw_File "
                        & "and compares what it gets; a checkout on a host "
                        & "whose line ending is two characters gives them "
                        & "back that way, so read it through a reader that "
                        & "takes the returns off");
               end if;
            end loop;
         end Visit_Reading;

         procedure Scan_Reading is new For_Each_Source (Visit_Reading);

         --  A file that names a built executable must account for the name
         --  the other host gives it. Crude on purpose: what is asked is that
         --  the file says .exe somewhere, which a file that has thought
         --  about it does and a file that has not does not.
         procedure Visit_Naming_Binary (Relative : String) is
            Text : constant String := Contents (Relative);

            function Holds (Word : String) return Boolean is
            begin
               for Index in Text'First .. Text'Last - Word'Length + 1 loop
                  if Text (Index .. Index + Word'Length - 1) = Word then
                     return True;
                  end if;
               end loop;
               return False;
            end Holds;
         begin
            if Relative = "tests/src/checks.adb" then
               return;
            end if;

            if (Holds ("bin/tests") or else Holds ("bin/model_runner"))
              and then not Holds (".exe")
            then
               Result.Performed := Result.Performed + 1;
               Fail (Relative & " names a built executable and never names "
                     & "the .exe form, so it looks for a file that is not "
                     & "there on the host that writes one");
            end if;
         end Visit_Naming_Binary;

         procedure Scan_Naming_Binary is new For_Each_Source
           (Visit_Naming_Binary);
      begin
         Scan_Reading ("tests/src");
         Scan_Reading ("tools/src");
         Scan_Naming_Binary ("tests/src");
         Scan_Naming_Binary ("tools/src");
      end;

      --  A host call is reached from a directory the project file picks per
      --  host -- src/platform in the library, tests/src/platform here, which
      --  is how raise_interrupt has a body for each. Anywhere else in the
      --  tests crate is one directory built for whatever machine you are on,
      --  so an import bound by its POSIX name links here and nowhere else,
      --  in the crate whose own checks demand that every host body compile
      --  for every host.
      --
      --  That happened. Captured_Output bound open, dup, dup2 and close by
      --  name, in tests/src, where there is no per-host anything. Hostkit
      --  already had the portable form: Assign is dup2 on POSIX and
      --  SetStdHandle on Windows, and says so in its own comment. So the
      --  rule is not that a test may never reach the host; it is that it
      --  does so from a directory the project file chooses, or through
      --  hostkit, and never by naming a symbol in the portable half.
      declare
         procedure Visit_Binding (Relative : String) is
            Text : constant String := Contents (Relative);

            function Holds (Word : String) return Boolean is
            begin
               for Index in Text'First .. Text'Last - Word'Length + 1 loop
                  if Text (Index .. Index + Word'Length - 1) = Word then
                     return True;
                  end if;
               end loop;
               return False;
            end Holds;
         begin
            --  Not this file: it names the pragma in the string it compares
            --  against, which is not a binding. And not the per-host
            --  directories, which are where a binding belongs.
            if Relative = "tests/src/checks.adb"
              or else T.Starts_With (Relative, "tests/src/platform/")
            then
               return;
            end if;

            Result.Performed := Result.Performed + 1;

            if Holds ("External_Name") or else Holds ("Convention => C") then
               Fail (Relative & " binds a host call by name; the tests crate "
                     & "is one directory for every host, so that links here "
                     & "and nowhere else -- reach the host through hostkit");
            end if;
         end Visit_Binding;

         procedure Scan_Bindings is new For_Each_Source (Visit_Binding);
      begin
         Scan_Bindings ("tests/src");

         --  And the tools crate, which has no per-host directories at all,
         --  so a binding there has nowhere it could legitimately live.
         Scan_Bindings ("tools/src");
      end;

      --  A test that can run the command can catch what it writes.
      --
      --  Generated text goes through the raw stream of
      --  Ada.Text_IO.Standard_Output, which Set_Output does not redirect, so
      --  a test that runs a generating command in the suite's own process
      --  writes the model's output into the middle of the suite's report.
      --  Seven fragments of it sat there on every run, and the same
      --  mechanism let a comparison of generated text compare one newline
      --  with itself for as long as it existed.
      --
      --  What this holds is that a file which can start the command has
      --  Captured_Output to hand. It does not hold that every call is
      --  wrapped -- a check that tried to match call sites matched every
      --  Run in the crate, including the fuzzing and conformance campaigns,
      --  and a check that matched one spelling of one name missed a third
      --  interactive session that was renaming the package it called
      --  through. This is the invariant that can be stated exactly.
      declare
         procedure Visit_Runner (Relative : String) is
            Text : constant String := Contents (Relative);

            function Holds (Word : String) return Boolean is
            begin
               for Index in Text'First .. Text'Last - Word'Length + 1 loop
                  if Text (Index .. Index + Word'Length - 1) = Word then
                     return True;
                  end if;
               end loop;
               return False;
            end Holds;
         begin
            --  Not this file: it names those units in the strings it
            --  compares against, which is not a with clause.
            if Relative = "tests/src/checks.adb" then
               return;
            end if;

            Result.Performed := Result.Performed + 1;

            if (Holds ("with Model_Runner.CLI.Driver;")
                or else Holds ("with Model_Runner.CLI.Interactive;"))
              and then not Holds ("with Captured_Output;")
            then
               Fail (Relative & " can run the command and does not with "
                     & "Captured_Output, so whatever it generates lands in "
                     & "the suite's own report");
            end if;
         end Visit_Runner;

         procedure Scan_Runners is new For_Each_Source (Visit_Runner);
      begin
         Scan_Runners ("tests/src");
      end;

      --  Every host body parses, not only the ones this build compiles.
      --
      --  src/platform holds five directories and a build uses two of them:
      --  linux and posix here, windows or macos elsewhere. The other three
      --  are production code that no compiler on this machine has ever seen,
      --  and the checks above read them as text -- layering, line length,
      --  which constants are dead -- which no amount of reading turns into
      --  parsing.
      --
      --  This is not hypothetical. The sibling hostkit crate shipped a
      --  Windows body holding ('\\') where Ada spells a backslash ('\'),
      --  and it was found by building on Windows and nowhere else. The
      --  check written there is this one; bringing it here was overdue,
      --  because this tree has three unbuilt directories to that one's two.
      --
      --  Semantics, not only syntax. -gnatc stops before code generation but
      --  after analysis, so the profiles in a body are checked against the
      --  spec all five share, names are resolved, and types have to agree.
      --  Nothing here needs the host's own libraries: these bodies bind to
      --  their host through Interfaces.C, whose declarations are the same
      --  everywhere, which is what makes the question askable at all from a
      --  machine of the wrong kind.
      --
      --  It was -gnats for a day, which parses and no more. A body whose
      --  Physical_Cores returned Integer where the spec says Natural passed
      --  that and fails this -- and a body nothing compiles is exactly where
      --  a profile drifts from the spec it implements.
      declare
         --  Through Alire, because the Ada compiler is the one the build
         --  used and it is not on the path: a bare gcc on a
         --  continuous-integration runner has no gnat1 behind it, and every
         --  one of the ten bodies was reported as failing to compile,
         --  including the two that had just been built. Checked on the
         --  machine that had one and nowhere else, which is the mistake this
         --  whole section exists to stop somebody making.
         Alr      : constant String :=
           Project_Tools.Processes.Locate_Command ("alr");
         Compiler : constant String :=
           Project_Tools.Processes.Locate_Command ("gcc");

         --  Absolute, because the child is run with its working directory
         --  set to the tree root: a path relative to where this command was
         --  started would be resolved again from there and find nothing,
         --  which is how the first version of this check reported that all
         --  ten bodies failed to parse, including the two this build had
         --  just compiled.
         Full : constant String := Ada.Directories.Full_Name (Root);

         --  Where the compiler is run, and so where it drops the .ali files
         --  analysis produces. The first version ran it in the tree root and
         --  left three of them lying there.
         Scratch : constant String := Full & "/obj/host-bodies";

         type Name_Access is access constant String;
         Hosts : constant array (1 .. 5) of Name_Access :=
           [new String'("linux"),
            new String'("macos"),
            new String'("posix"),
            new String'("unsupported"),
            new String'("windows")];

         --  The two trees that hold per-host bodies. The tests crate has one
         --  too -- raise_interrupt, a body for each host -- and it was left
         --  out of this walk, which is how a POSIX-only binding got into the
         --  crate that holds this check.
         type Tree is record
            Root  : Name_Access;
            Under : Name_Access;
         end record;

         Trees : constant array (1 .. 2) of Tree :=
           [(new String'("src/platform"), new String'("src/library")),
            (new String'("tests/src/platform"), new String'("tests/src"))];

         Parsed : Natural := 0;
         Broken : Natural := 0;

         --  Every one of them failing is a statement about the compiler.
         function Failed_All return Boolean is (Broken = Parsed);
      begin
         Result.Performed := Result.Performed + 1;

         if Compiler = "" then
            Fail ("no gcc on the path, so no host body could be compiled and "
                  & "the three directories this build does not build went "
                  & "unchecked");
         else
            Ada.Directories.Create_Path (Scratch);

            for Each of Trees loop
               for Host of Hosts loop
                  declare
                     Where  : constant String :=
                       Full & "/" & Each.Root.all & "/" & Host.all;
                     Search : Ada.Directories.Search_Type;
                     Item   : Ada.Directories.Directory_Entry_Type;
                  begin
                     if Ada.Directories.Exists (Where) then
                        Ada.Directories.Start_Search (Search, Where, "*.ad[sb]");

                        while Ada.Directories.More_Entries (Search) loop
                           Ada.Directories.Get_Next_Entry (Search, Item);

                           declare
                              Name : constant String :=
                                Ada.Directories.Simple_Name (Item);
                              Args : Project_Tools.Processes.Argument_Vectors
                                       .Vector;
                           begin
                              if Alr /= "" then
                                 Args.Append
                                   (Ada.Strings.Unbounded.To_Unbounded_String
                                      ("exec"));
                                 Args.Append
                                   (Ada.Strings.Unbounded.To_Unbounded_String
                                      ("--"));
                                 Args.Append
                                   (Ada.Strings.Unbounded.To_Unbounded_String
                                      ("gcc"));
                              end if;

                              Args.Append
                                (Ada.Strings.Unbounded.To_Unbounded_String
                                   ("-c"));
                              Args.Append
                                (Ada.Strings.Unbounded.To_Unbounded_String
                                   ("-gnatc"));
                              Args.Append
                                (Ada.Strings.Unbounded.To_Unbounded_String
                                   ("-I"));
                              Args.Append
                                (Ada.Strings.Unbounded.To_Unbounded_String
                                   (Full & "/" & Each.Under.all));
                              Args.Append
                                (Ada.Strings.Unbounded.To_Unbounded_String
                                   ("-gnat2022"));
                              Args.Append
                                (Ada.Strings.Unbounded.To_Unbounded_String
                                   ("-x"));
                              Args.Append
                                (Ada.Strings.Unbounded.To_Unbounded_String
                                   ("ada"));
                              Args.Append
                                (Ada.Strings.Unbounded.To_Unbounded_String
                                   (Where & "/" & Name));

                              Result.Performed := Result.Performed + 1;
                              Parsed := Parsed + 1;

                              if Project_Tools.Processes.Run_Status
                                   (Label   => "parse " & Each.Root.all & "/"
                                               & Host.all & "/" & Name,
                                    Dir     => Scratch,
                                    Program =>
                                      (if Alr /= "" then Alr else Compiler),
                                    Args    => Args,
                                    Quiet   => True) /= 0
                              then
                                 Broken := Broken + 1;
                                 Fail (Each.Root.all & "/" & Host.all & "/"
                                       & Name
                                       & " does not compile; it would fail on "
                                       & "that host and nowhere else");
                              end if;
                           end;
                        end loop;

                        Ada.Directories.End_Search (Search);
                     end if;
                  end;
               end loop;
            end loop;

            --  A compiler that cannot compile anything reports every body
            --  as broken, which is what happened: a bare gcc with no gnat1
            --  behind it failed on all ten, including the two the build had
            --  just made. So one file that must compile is compiled first,
            --  and if that fails the answer is that the question could not
            --  be asked rather than that the tree is broken.
            Result.Performed := Result.Performed + 1;

            if Parsed > 0 and then Failed_All then
               Fail ("every host body failed to compile, which is what a "
                     & "compiler that cannot run looks like; the tree is "
                     & "more likely sound than the tool");
            end if;

            --  And that each host gets exactly one body for each spec.
            --
            --  Compiling a body says it is well formed; it says nothing
            --  about whether the host that needs it has one. The project
            --  file builds linux with posix, macos with posix, windows
            --  alone and unsupported alone, so a spec whose bodies were
            --  written for some of those and not the rest fails to link on
            --  the others -- on that host and nowhere else, which is the
            --  failure this whole section exists to stop. Two bodies for
            --  one spec on the same host is the same mistake the other way
            --  round, and the project file would refuse it there.
            declare
               --  Each host as the directories the project file gives it.
               type Host_Set is array (1 .. 2) of Name_Access;

               Nothing_More : constant Name_Access := new String'("");
               Posix        : constant Name_Access := new String'("posix");

               Sets : constant array (1 .. 4) of Host_Set :=
                 [[Hosts (1), Posix],
                  [Hosts (2), Posix],
                  [Hosts (4), Nothing_More],
                  [Hosts (5), Nothing_More]];

               --  Every platform spec, by the body name it asks for.
               Specs : Natural := 0;

               function Bodies_For (Spec : String; Set : Host_Set)
                 return Natural
               is
                  Found : Natural := 0;
               begin
                  for Where of Set loop
                     if Where.all /= ""
                       and then Ada.Directories.Exists
                                  (Full & "/src/platform/" & Where.all
                                   & "/" & Spec)
                     then
                        Found := Found + 1;
                     end if;
                  end loop;
                  return Found;
               end Bodies_For;

               Search : Ada.Directories.Search_Type;
               Item   : Ada.Directories.Directory_Entry_Type;
            begin
               Ada.Directories.Start_Search
                 (Search, Full & "/src/library",
                  "model_runner-platform-*.ads");

               while Ada.Directories.More_Entries (Search) loop
                  Ada.Directories.Get_Next_Entry (Search, Item);
                  Specs := Specs + 1;

                  declare
                     Spec : constant String :=
                       Ada.Directories.Simple_Name (Item);
                     Body_Name : constant String :=
                       Spec (Spec'First .. Spec'Last - 1) & 'b';
                     --  A package under this name is usually the host
                     --  boundary itself, and then it needs one body per
                     --  host and no other. It may instead be portable code
                     --  that goes through the boundary -- a child of a
                     --  platform package, using what its parent found --
                     --  and then it has one body in the library and none
                     --  per host. The two cannot be confused, because a
                     --  package cannot have both, and requiring one or the
                     --  other keeps the rule as strict as it was.
                     Portable : constant Boolean :=
                       Ada.Directories.Exists
                         (Full & "/src/library/" & Body_Name);
                  begin
                     for Set of Sets loop
                        Result.Performed := Result.Performed + 1;

                        if Portable then
                           if Bodies_For (Body_Name, Set) /= 0 then
                              Fail (Body_Name & " has a body in the library "
                                    & "and"
                                    & Natural'Image
                                        (Bodies_For (Body_Name, Set))
                                    & " for the host built from "
                                    & Set (1).all
                                    & (if Set (2).all = "" then ""
                                       else " and " & Set (2).all)
                                    & ", where it must have one or the "
                                    & "other");
                           end if;

                        elsif Bodies_For (Body_Name, Set) /= 1 then
                           Fail (Body_Name & " has"
                                 & Natural'Image (Bodies_For (Body_Name, Set))
                                 & " bodies for the host built from "
                                 & Set (1).all
                                 & (if Set (2).all = "" then ""
                                    else " and " & Set (2).all)
                                 & ", where a host needs exactly one");
                        end if;
                     end loop;
                  end;
               end loop;

               Ada.Directories.End_Search (Search);

               Result.Performed := Result.Performed + 1;
               if Specs = 0 then
                  Fail ("no platform specs were found, so the check that "
                        & "each host implements them all matched nothing");
               end if;
            end;

            --  A run that compiled nothing found nothing, and would say so
            --  by saying nothing at all.
            Result.Performed := Result.Performed + 1;
            if Parsed < 8 then
               Fail ("only" & Natural'Image (Parsed) & " host bodies were "
                     & "compiled; this tree has ten, so the walk is no "
                     & "longer finding them");
            end if;

            begin
               Ada.Directories.Delete_Tree (Scratch);
            exception
               when others =>
                  null;
            end;
         end if;
      end;

      --  Every figure group names the model it was taken with.
      --
      --  The drafting row cannot be reproduced by anyone, because the second
      --  model it drafts with was requantized locally and nothing recorded
      --  which source or which tool. A figure that describes a model and does
      --  not name it is a figure only its author can check, and this
      --  repository had six of those and one -- the external-model record --
      --  that named its file precisely. The rule is now the same everywhere:
      --  a group says what it ran on, and "none" is an answer for the groups
      --  that time kernels on tensors this tool builds itself.
      declare
         Path  : constant String := Root & "/docs/measured-figures.txt";
         File  : Ada.Text_IO.File_Type;
         Named : Natural := 0;
         Groups : Natural := 0;
         Ready  : Boolean := False;
      begin
         Result.Performed := Result.Performed + 1;

         if Ada.Directories.Exists (Path) then
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
            while not Ada.Text_IO.End_Of_File (File) loop
               declare
                  Line : constant String := Ada.Text_IO.Get_Line (File);
               begin
                  if Project_Tools.Text.Starts_With (Line, "# model:") then
                     Named := Named + 1;
                     Ready := True;

                  elsif Line'Length > 18
                    and then Line (Line'First) not in ' ' | '#'
                  then
                     --  A fingerprint line: a name, a sixteen-digit digest
                     --  and the sources behind it.
                     Groups := Groups + 1;

                     if not Ready then
                        Fail ("a figure group in docs/measured-figures.txt "
                              & "has no '# model:' line before it, so what "
                              & "it was measured on is not recorded: "
                              & Line (Line'First
                                      .. Natural'Min (Line'Last,
                                                      Line'First + 20)));
                     end if;

                     Ready := False;
                  end if;
               end;
            end loop;
            Ada.Text_IO.Close (File);

            if Groups = 0 then
               Fail ("no figure groups were found in "
                     & "docs/measured-figures.txt, so whether each names its "
                     & "model was not asked");
            end if;
         end if;
      end;

      --  Every English message key has a pseudo-locale counterpart.
      --
      --  The suite already fails when one does not, in four assertions that
      --  name the symptom -- a key renders identically under pseudo-
      --  translation, a partial locale will not load -- and a fifth about a
      --  backend, because a catalog that will not load takes everything
      --  downstream with it. None of them says "you added a key and not its
      --  twin", which is the whole of what happened, three times, to me.
      declare
         Path : constant String :=
           Root & "/resources/messages/catalog.txt";

         --  The pseudo-locale's keys, gathered in one pass and asked in the
         --  next. Two passes over the file rather than a search inside a
         --  search: the same file cannot be open twice, which is how the
         --  first version of this ended.
         Twins   : Ada.Strings.Unbounded.Unbounded_String;
         English : Natural := 0;

         --  The key of a line, or the empty string where there is none.
         function Key_Of (Line : String; Prefix : String) return String is
         begin
            if Line'Length <= Prefix'Length
              or else Line (Line'First .. Line'First + Prefix'Length - 1)
                      /= Prefix
            then
               return "";
            end if;

            for I in Line'First + Prefix'Length .. Line'Last loop
               if Line (I) = ' ' or else Line (I) = '=' then
                  return Line (Line'First + Prefix'Length .. I - 1);
               end if;
            end loop;

            return "";
         end Key_Of;

         File : Ada.Text_IO.File_Type;
      begin
         Result.Performed := Result.Performed + 1;

         if Ada.Directories.Exists (Path) then
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
            while not Ada.Text_IO.End_Of_File (File) loop
               declare
                  Key : constant String :=
                    Key_Of (Ada.Text_IO.Get_Line (File), "qps.");
               begin
                  if Key /= "" then
                     Ada.Strings.Unbounded.Append (Twins, "|" & Key & "|");
                  end if;
               end;
            end loop;
            Ada.Text_IO.Close (File);

            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
            while not Ada.Text_IO.End_Of_File (File) loop
               declare
                  Key : constant String :=
                    Key_Of (Ada.Text_IO.Get_Line (File), "en.");
               begin
                  if Key /= "" then
                     English := English + 1;

                     if not Project_Tools.Text.Contains
                              (Ada.Strings.Unbounded.To_String (Twins),
                               "|" & Key & "|")
                     then
                        Fail ("the catalog has en." & Key & " and no qps."
                              & Key & "; a key without its pseudo-locale twin "
                              & "is an untranslated string nothing can see");
                     end if;
                  end if;
               end;
            end loop;
            Ada.Text_IO.Close (File);

            if English = 0 then
               Fail ("no English message keys were found in the catalog, so "
                     & "whether each has a pseudo-locale twin was not asked");
            end if;
         end if;
      end;

      --  No model file inside the repository, tracked or not.
      --
      --  A machine that runs the published figures has models on it, and the
      --  smallest of them is four hundred megabytes. One copied into the
      --  tree for convenience would be ignored by git today and packaged by
      --  the release tomorrow, and nothing here asked. The generated
      --  fixtures are the exception the ignore file already names: they are
      --  kilobytes and this program writes them itself.
      declare
         Found : Natural := 0;

         procedure Walk (Where : String) is
            Search : Ada.Directories.Search_Type;
            Item   : Ada.Directories.Directory_Entry_Type;
         begin
            if not Ada.Directories.Exists (Where) then
               return;
            end if;

            Ada.Directories.Start_Search
              (Search, Where, "",
               [Ada.Directories.Ordinary_File => True,
                Ada.Directories.Directory => True,
                others => False]);
            while Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Item);
               declare
                  Simple : constant String :=
                    Ada.Directories.Simple_Name (Item);
                  Full   : constant String :=
                    Ada.Directories.Full_Name (Item);
               begin
                  if Simple /= "." and then Simple /= ".."
                    and then Simple /= ".git"
                    and then Simple /= "fixtures"
                    and then Simple /= "obj"
                  then
                     if Ada.Directories."=" (Ada.Directories.Kind (Full),
                                             Ada.Directories.Directory)
                     then
                        Walk (Full);
                     elsif Simple'Length > 5
                       and then Simple (Simple'Last - 4 .. Simple'Last)
                                = ".gguf"
                     then
                        Found := Found + 1;
                        Fail ("a model file sits inside the repository at "
                              & Full & "; models belong beside it, not in it");
                     end if;
                  end if;
               end;
            end loop;
            Ada.Directories.End_Search (Search);
         end Walk;
      begin
         Result.Performed := Result.Performed + 1;
         Walk (Root);
      end;

      --  enough above zero that a run which stops checking cannot pass.
      declare
         Fewest_Checks : constant := 3_000;
      begin
         Result.Performed := Result.Performed + 1;
         if Result.Performed < Fewest_Checks then
            Fail ("this run performed" & Natural'Image (Result.Performed)
                  & " checks, fewer than the" & Natural'Image (Fewest_Checks)
                  & " this repository has; something stopped checking rather "
                  & "than found nothing to say");
         end if;
      end;

      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "  checks" & Natural'Image (Result.Performed)
         & ", failures" & Natural'Image (Result.Failed));
   end Run;

end Checks;
