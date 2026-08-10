with Ada.Directories;
with Ada.Text_IO;
with Interfaces;
use type Interfaces.Unsigned_64;

with Hostkit.Fs;

with Ada.Strings.Unbounded;
with Project_Tools.Ada_Source;
with Project_Tools.Processes;
with Project_Tools.Files;
with Project_Tools.Text;
with Project_Tools.Tree_Checks;

with Docs_Generation;
with Library_Surface;
with Reserved_Codes;
with Template_Registry;
with Tiny_Model;
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

   procedure Run (Root : String; Result : out Report) is

      procedure Fail (Detail : String) is
      begin
         Result.Failed := Result.Failed + 1;
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "  fail: " & Detail);
      end Fail;

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
      function Contents (Relative : String) return String is
      begin
         if Files.File_Exists (Path (Relative)) then
            return Files.Read_Raw_File (Path (Relative));
         else
            return "";
         end if;
      end Contents;

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
               Visit (Hostkit.Fs.Join (Where, Dirs.Simple_Name (Item)));
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
      --  The README names hand-written vector code among what is absent: the
      --  kernels are Ada and the compiler vectorizes them, and nothing here
      --  is assembly, an intrinsic, or another language. That claim is what
      --  makes the speed figures mean what they say, and it is the kind that
      --  erodes -- one intrinsic in one hot loop, for a good reason, and the
      --  sentence in the README is quietly false.
      --
      --  Binding to a host call is not writing in another language: the
      --  platform bodies reach mmap and isatty through Interfaces.C and stay
      --  ordinary Ada. What is refused is code in another language living
      --  here, and instructions written by hand.
      --
      --  The token sweep is project_tools': it walks the tree itself and
      --  counts what it finds into the same total as everything else here,
      --  which is what a check written twice would have had to agree with.
      --  It counts its own failures into the same total and names the file
      --  itself, so there is nothing to add here: reporting again would count
      --  one occurrence twice.
      Result.Performed := Result.Performed + 1;

      Project_Tools.Tree_Checks.Check_No_Forbidden_Tokens
        (Errors           => Result.Failed,
         Dir              => Path ("src"),
         Forbidden_Tokens =>
           [1 => Ada.Strings.Unbounded.To_Unbounded_String ("Machine_Code")],
         Purpose          => "instructions written by hand");

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
         for Index in 1 .. Opt.Option_Count loop
            if Opt.Option_Help (Index) /= "" then
               if Opt.Option_Commands (Index) (Opt.Command_Run) then
                  Reached ("help.run." & Opt.Option_Help (Index));
               end if;
               if Opt.Option_Commands (Index) (Opt.Command_Inspect) then
                  Reached ("help.inspect." & Opt.Option_Help (Index));
               end if;
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
         Room  : constant := 400;
         Width : constant := 64;
         Named : constant := 64;

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
                  Fail ("the message catalog does not parse in " & Name
                        & "; the runtime refused it, which it does for the "
                        & "whole file -- look for a line added since it last "
                        & "loaded, and for a placeholder name the runtime "
                        & "does not accept");
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
         function Excused (Name : String) return Boolean
         is (Name in "Run_Process" | "Physical_Cores" | "Host_Name"
                     | "No_Color_Requested" | "Failure_Name" | "Interrupts");

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
      begin
         Accepted_Names ("Name");
         Accepted_Names ("Cutting");
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
      --  No test calls the driver without catching what it writes.
      --
      --  Generated text goes through the raw stream of
      --  Ada.Text_IO.Standard_Output, which Set_Output does not redirect, so
      --  a test that runs a generating command in the suite's own process
      --  writes the model's output into the middle of the suite's report.
      --  Seven fragments of it sat there on every run, and the same
      --  mechanism is what let a comparison of generated text compare one
      --  newline with itself for as long as it existed.
      --
      --  Ran in Tests.CLI_Cases is the one way in, and it captures. This
      --  says so, because the next call written straight to the driver would
      --  put the fragments back and nothing would notice.
      declare
         Text  : constant String :=
           Contents ("tests/src/tests-cli_cases.adb");
         Calls : Natural := 0;
      begin
         for Index in Text'First .. Text'Last - 27 loop
            if Text (Index .. Index + 27) = "Model_Runner.CLI.Driver.Run " then
               Calls := Calls + 1;
            end if;
         end loop;

         Result.Performed := Result.Performed + 1;
         if Calls /= 1 then
            Fail ("the command-line tests call the driver directly"
                  & Natural'Image (Calls) & " times; exactly one of those is "
                  & "Ran, which catches what the command writes, and the "
                  & "rest write the model's output into the suite's own "
                  & "report");
         end if;
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

         Parsed : Natural := 0;
      begin
         Result.Performed := Result.Performed + 1;

         if Compiler = "" then
            Fail ("no gcc on the path, so no host body could be compiled and "
                  & "the three directories this build does not build went "
                  & "unchecked");
         else
            Ada.Directories.Create_Path (Scratch);

            for Host of Hosts loop
               declare
                  Where  : constant String :=
                    Full & "/src/platform/" & Host.all;
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
                                (Full & "/src/library"));
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
                                (Label   => "parse " & Host.all & "/" & Name,
                                 Dir     => Scratch,
                                 Program => Compiler,
                                 Args    => Args,
                                 Quiet   => True) /= 0
                           then
                              Fail ("src/platform/" & Host.all & "/" & Name
                                    & " does not compile; it would fail on "
                                    & "that host and nowhere else");
                           end if;
                        end;
                     end loop;

                     Ada.Directories.End_Search (Search);
                  end if;
               end;
            end loop;

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
                  begin
                     for Set of Sets loop
                        Result.Performed := Result.Performed + 1;

                        if Bodies_For (Body_Name, Set) /= 1 then
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
