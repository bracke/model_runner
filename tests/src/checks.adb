with Ada.Directories;
with Ada.Text_IO;
with Interfaces;
use type Interfaces.Unsigned_64;

with Hostkit.Fs;

with Ada.Strings.Unbounded;
with Project_Tools.Ada_Source;
with Project_Tools.Files;
with Project_Tools.Text;
with Project_Tools.Tree_Checks;

with Docs_Generation;
with Reserved_Codes;
with Template_Registry;

with Model_Runner;
with Model_Runner.Errors;
with Model_Runner.Backend;
with Model_Runner.Backend.CPU;
with Model_Runner.CLI.Options;
with Model_Runner.GGUF;
with Model_Runner.Quantization;
with Model_Runner.Templates;
with Model_Runner.Text;

package body Checks is

   use type Model_Runner.Errors.Error_Code;
   use type Model_Runner.Backend.Backend_Kind;
   use type Template_Registry.Outcome;
   use type Template_Registry.Text_Access;

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
      begin
         Result.Performed := Result.Performed + 1;
         if Listed = "" then
            Fail ("README.md has no quantization row; the check no longer "
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
         Check (Able.Kind = Model_Runner.Backend.Backend_CPU,
                "the CPU backend describes itself as another one");
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
            elsif Index <= Formats + Backends then
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
         Opened : constant String := "## Chat-template constructs";
         Seen   : array (1 .. Template_Registry.Count) of Boolean :=
           [others => False];
         Rows   : Natural := 0;

         --  The chat-template section, up to the heading after it.
         function Section return String is
            From : Natural := 0;
         begin
            if Matrix'Length < Opened'Length then
               return "";
            end if;
            for Index in Matrix'First .. Matrix'Last - Opened'Length + 1 loop
               if Matrix (Index .. Index + Opened'Length - 1) = Opened then
                  From := Index + Opened'Length;
                  exit;
               end if;
            end loop;
            if From = 0 then
               return "";
            end if;

            for Index in From .. Matrix'Last - 2 loop
               if Matrix (Index) = Character'Val (10)
                 and then Matrix (Index + 1 .. Index + 2) = "##"
               then
                  return Matrix (From .. Index);
               end if;
            end loop;
            return Matrix (From .. Matrix'Last);
         end Section;

         Body_Text : constant String := Section;
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

         Scan_Suppliers ("src/library");
         Scan_Suppliers ("src/main");

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

      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "  checks" & Natural'Image (Result.Performed)
         & ", failures" & Natural'Image (Result.Failed));
   end Run;

end Checks;
