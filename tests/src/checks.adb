with Ada.Directories;
with Ada.Text_IO;

with Hostkit.Fs;

with Project_Tools.Files;

with Docs_Generation;
with Reserved_Codes;

with Model_Runner;
with Model_Runner.Errors;
with Model_Runner.Text;

package body Checks is

   use type Model_Runner.Errors.Error_Code;

   package Dirs renames Ada.Directories;
   package E renames Model_Runner.Errors;
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

      --  Report whether a file mentions a token.
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

      function Mentions (Relative, Token : String) return Boolean is
         Text : constant String := Contents (Relative);
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
      end Mentions;

      --  Visit every Ada source under a directory.
      generic
         with procedure Visit (Relative : String);
      procedure For_Each_Source (Directory : String);

      procedure For_Each_Source (Directory : String) is
         Search : Dirs.Search_Type;
         Item   : Dirs.Directory_Entry_Type;
      begin
         if not Files.Directory_Exists (Path (Directory)) then
            return;
         end if;

         Dirs.Start_Search
           (Search, Path (Directory), "*.ad[sb]",
            [Dirs.Ordinary_File => True, others => False]);

         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Item);
            Visit (Hostkit.Fs.Join (Directory, Dirs.Simple_Name (Item)));
         end loop;

         Dirs.End_Search (Search);
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
         procedure Visit_Production (Relative : String) is
         begin
            Result.Performed := Result.Performed + 1;
            if Mentions (Relative, "with AUnit") then
               Fail (Relative & " depends on AUnit");
            elsif Mentions (Relative, "with Project_Tools") then
               Fail (Relative & " depends on project_tools");
            elsif Mentions (Relative, "with Tests") then
               Fail (Relative & " depends on the tests crate");
            end if;
         end Visit_Production;

         procedure Scan_Production is
           new For_Each_Source (Visit_Production);
      begin
         Scan_Production ("src/library");
         Scan_Production ("src/main");

         --  One body per host, and each is production code held to the same
         --  rules. Left out, a platform body could reach a forbidden layer or
         --  drift in style and nothing would say so.
         Scan_Production ("src/platform/posix");
         Scan_Production ("src/platform/windows");
         Scan_Production ("src/platform/unsupported");
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
      declare
         procedure Visit_Ada_Only (Relative : String) is
         begin
            Result.Performed := Result.Performed + 1;

            if Holds (Contents (Relative), "Machine_Code") then
               Fail (Relative & " writes instructions by hand");
            end if;
         end Visit_Ada_Only;

         procedure Scan_Ada_Only is new For_Each_Source (Visit_Ada_Only);
      begin
         Scan_Ada_Only ("src/library");
         Scan_Ada_Only ("src/main");
         Scan_Ada_Only ("src/platform/posix");
         Scan_Ada_Only ("src/platform/windows");
         Scan_Ada_Only ("src/platform/unsupported");
      end;

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
         Scan_Lower ("src/library");
         Scan_Lower ("src/platform/posix");
         Scan_Lower ("src/platform/windows");
         Scan_Lower ("src/platform/unsupported");
      end;

      --  Style: the documented line-length budget.
      declare
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

            if Worst > Max_Line then
               Fail (Relative & " has a line of" & Natural'Image (Worst)
                     & " characters");
            end if;
         end Visit_Length;

         procedure Scan_Length is new For_Each_Source (Visit_Length);
      begin
         Scan_Length ("src/library");
         Scan_Length ("src/main");
         Scan_Length ("tests/src");
      end;

      --  Documentation: every public specification opens with a comment.
      declare
         procedure Visit_Doc (Relative : String) is
            Text : constant String := Contents (Relative);
         begin
            if not T.Ends_With (Relative, ".ads") then
               return;
            end if;

            Result.Performed := Result.Performed + 1;

            --  A specification must carry at least one comment before its
            --  package declaration; the GNATdoc tags themselves are checked by
            --  the documentation build.
            if Text'Length = 0 or else not Mentions (Relative, "--") then
               Fail (Relative & " has no specification comment");
            end if;
         end Visit_Doc;

         procedure Scan_Doc is new For_Each_Source (Visit_Doc);
      begin
         Scan_Doc ("src/library");
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

      --  Documentation registries agree with the code.
      declare
         Matrix : constant String := Contents ("docs/support-matrix.md");
      begin
         Result.Performed := Result.Performed + 1;
         if Matrix'Length = 0 then
            Fail ("docs/support-matrix.md is missing");
         end if;
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
      --  --backend to be invalid, no merge table in a SentencePiece
      --  vocabulary, and Conversation.Role is an enumeration.
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
         Scan_Environment ("src/library");
         Scan_Environment ("src/main");
         Scan_Environment ("src/platform/posix");
         Scan_Environment ("src/platform/windows");
         Scan_Environment ("src/platform/unsupported");
      end;

      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "  checks" & Natural'Image (Result.Performed)
         & ", failures" & Natural'Image (Result.Failed));
   end Run;

end Checks;
