with Ada.Directories;
with Ada.Strings.Unbounded;
with Hostkit.Process;
with Hostkit.Fs;
with Project_Tools.Files;

package body Transfer_Curriculum is
   use Ada.Strings.Unbounded;
   use type Hostkit.String_Vectors.Vector;
   LF : constant String := [1 => ASCII.LF];
   function Name (Which : Positive) return String is
     (case Which is when 1 => "text-crlf", when 2 => "toml-empty", when 3 => "toml-boolean",
         when 4 => "regexp-property", when 5 => "regexp-backreference", when 6 => "version-refnames",
         when others => "invalid");
   function Repository (Which : Positive) return String is
     (if Which <= 3 then "project_tools" elsif Which <= 5 then "regexp" else "versionlib");
   function Revision (Which : Positive) return String is
     (case Which is
         when 1 => "e0a591849bcf1bbf41936b793da7fa1079a377ea",
         when 2 => "bddc1ebef8572662167610c4dfbbc8a337b590c0",
         when 3 => "eaf8dd79b889b78e2540ef2c070d17d8483314ca",
         when 4 => "d6606bd1b0b1b098bf67abbdfa4fb7384d86436e",
         when 5 => "83b749f1fae6675cd3db846633250c2036c43163",
         when 6 => "d096a96cee8523581d422cad5e41bc76d5b59b0b",
         when others => "invalid");
   function Notes (Which : Positive) return String is
     (case Which is
         when 1 => "Fix Project_Tools.Text.Line_Value so values from CRLF files do not retain the"
           & " carriage return, including a final CR without LF. Preserve LF, missing-key and empty-value behavior."
           & " Change only src/project_tools-text.adb; keep the public API and other functions unchanged.",
         when 2 => "Fix Project_Tools.TOML.Parse_String_After: an empty quoted value is Parsed_String"
           & " with an empty value, not a reason to read a later occurrence of the key. Preserve nonempty,"
           & " missing and malformed handling. Change only src/project_tools-toml.adb.",
         when 3 => "Add Project_Tools.TOML.Boolean_Parse_Status (Parsed_Boolean, Missing_Boolean,"
           & " Malformed_Boolean), Boolean_Parse_Result with Status default Missing_Boolean and Value Boolean"
           & " default False, and Parse_Boolean_After (Text, Key : String; From : Positive) returning that record."
           & " Follow the existing natural and string parser conventions: find Key at or after From, skip spaces,"
           & " parse lowercase true or false, distinguish missing from malformed, return False on those outcomes,"
           & " and contain Constraint_Error as malformed. Change only src/project_tools-toml.ads and .adb.",
         when 4 => "Fix Regexp character classes: literal p and P in [dp], [pq] and [^p] must compile"
           & " as letters. A Unicode property inside brackets is written [\p{digit}], recognized after the"
           & " escape; outside properties must keep working. Preserve ordinary classes and invalid-property"
           & " diagnostics. Change only src/regexp.adb.",
         when 5 => "Fix Regexp so a backreference consumes its entire captured span, including groups"
           & " longer than one character: (ab)\1 must fully match abab and reject abac. Preserve captures,"
           & " alternatives, quantified groups and matching options. Keep ordinary patterns working and bound"
           & " pathological backtracking using the existing match-limit result. Change only src/regexp.adb.",
         when 6 => "Fix Version.Ref_Names.Is_Valid_Ref_Name: valid multi-level ref names must not be"
           & " restricted to an allowlist of familiar hierarchies. refs/pull/12/head, refs/bisect/good and"
           & " vendor/topic are valid; retain grammar and path-safety rejection of malformed or unsafe names."
           & " Preserve the public API and branch/tag/remote validation. Change only src/version-ref_names.adb.",
         when others => "invalid");
   function Paths (Which : Positive) return Hostkit.String_Vectors.Vector is
     (case Which is
         when 1 => [To_Unbounded_String ("src/project_tools-text.adb")],
         when 2 => [To_Unbounded_String ("src/project_tools-toml.adb")],
         when 3 => [To_Unbounded_String ("src/project_tools-toml.ads"),
                    To_Unbounded_String ("src/project_tools-toml.adb")],
         when 4 | 5 => [To_Unbounded_String ("src/regexp.adb")],
         when others => [To_Unbounded_String ("src/version-ref_names.adb")]);

   function Test_Source (Which : Positive; Hidden : Boolean) return String is
      Unit_Name : constant String := (if Hidden then "Hidden_Test" else "Test_Add");
      Imports : constant String :=
        (case Which is when 1 => "with Project_Tools.Text;", when 2 | 3 => "with Project_Tools.TOML;",
            when 4 | 5 => "with Regexp;", when others => "with Version.Ref_Names;");
      Declarations : constant String :=
        (case Which is
            when 1 => "   package P renames Project_Tools.Text;",
            when 2 | 3 => "   package P renames Project_Tools.TOML;" & LF
              & "   use type P.String_Parse_Status;" & LF
              & (if Which = 3 then "   use type P.Boolean_Parse_Status;" & LF
                   & "   use type P.Boolean_Parse_Result;" & LF
                   & "   Default_Value : P.Boolean_Parse_Result;" & LF else "")
              & "   use type Ada.Strings.Unbounded.Unbounded_String;" & LF
              & (if Which = 2 then "   Input : constant String := ""key = "" & Character'Val (34)"
                   & " & Character'Val (34) & ASCII.LF & ""key = 'later'"";" else ""),
            when 4 | 5 => "   use type Regexp.Compile_Status;" & LF & "   use type Regexp.Match_Status;" & LF
              & "   procedure Match (Pattern, Text : String; Expected : Boolean) is" & LF
              & "      C : constant Regexp.Compile_Result := Regexp.Compile (Pattern);" & LF
              & "   begin" & LF & "      Check (C.Status = Regexp.Compile_Ok, ""compile "" & Pattern);" & LF
              & "      Check ((Regexp.Matches_Entire (C.Expression, Text).Status = Regexp.Match_Ok) = Expected,"
              & " ""match "" & Pattern);" & LF & "   end Match;",
            when others => "   package P renames Version.Ref_Names;");
      Checks : Unbounded_String;
      procedure Add (Text : String) is
      begin
         Append (Checks, "   " & Text & LF);
      end Add;
   begin
      case Which is
         when 1 =>
            Add ("Check (P.Line_Value (""locale = en"" & ASCII.CR & ASCII.LF, ""locale"") = ""en"", ""CRLF"");");
            Add ("Check (P.Line_Value (""locale = da"" & ASCII.LF, ""locale"") = ""da"", ""LF"");");
            if Hidden then
               Add ("Check (P.Line_Value (""locale = fr"" & ASCII.CR, ""locale"") = ""fr"", ""final CR"");");
               Add ("Check (P.Line_Value (""x = other"" & ASCII.LF, ""missing"") = """", ""missing"");");
               Add ("Check (P.Line_Value (""locale = "" & ASCII.CR & ASCII.LF, ""locale"") = """", ""empty"");");
               Add ("Check (P.Line_Value (""locale = sv"", ""locale"") = ""sv"", ""unterminated"");");
            end if;
         when 2 =>
            Add ("Check (P.Parse_String_After (Input, ""key ="", 1).Status = P.Parsed_String, ""empty status"");");
            Add ("Check (Ada.Strings.Unbounded.Length (P.Parse_String_After"
                 & " (Input, ""key ="", 1).Value) = 0, ""first empty"");");
            if Hidden then
               Add ("Check (P.Parse_String_After (""name = """"alpha"""""", ""name ="", 1).Value ="
                    & " Ada.Strings.Unbounded.To_Unbounded_String (""alpha""), ""nonempty"");");
               Add ("Check (P.Parse_String_After (""other = 1"", ""name ="", 1).Status ="
                    & " P.Missing_String, ""missing"");");
               Add ("Check (P.Parse_String_After (""name = 42"", ""name ="", 1).Status ="
                    & " P.Malformed_String, ""malformed"");");
               Add ("Check (P.Parse_String_After (""k = ''"", ""k ="", 1).Status = P.Parsed_String"
                    & " and then Ada.Strings.Unbounded.Length (P.Parse_String_After"
                    & " (""k = ''"", ""k ="", 1).Value) = 0, ""single quotes"");");
            end if;
         when 3 =>
            Add ("Check (P.Parse_Boolean_After (""x = true"", ""x ="", 1) ="
                 & " P.Boolean_Parse_Result'(P.Parsed_Boolean, True), ""true"");");
            Add ("Check (P.Parse_Boolean_After (""x = false"", ""x ="", 1) ="
                 & " P.Boolean_Parse_Result'(P.Parsed_Boolean, False), ""false"");");
            if Hidden then
               Add ("Check (Default_Value.Status = P.Missing_Boolean and then not Default_Value.Value,"
                    & " ""record defaults"");");
               Add ("Check (P.Parse_Boolean_After (""x = TRUE"", ""x ="", 1).Status ="
                    & " P.Malformed_Boolean, ""malformed"");");
               Add ("Check (P.Parse_Boolean_After (""y = true"", ""x ="", 1).Status ="
                    & " P.Missing_Boolean, ""missing"");");
               Add ("Check (not P.Parse_Boolean_After (""x = 7"", ""x ="", 1).Value, ""bad value"");");
               Add ("Check (P.Parse_Boolean_After (""x = true x = false"", ""x ="", 9).Status ="
                    & " P.Parsed_Boolean and then not P.Parse_Boolean_After"
                    & " (""x = true x = false"", ""x ="", 9).Value, ""offset"");");
               Add ("Check (P.Parse_Natural_After (""n = 17"", ""n ="", 1).Value = 17, ""natural retained"");");
            end if;
         when 4 =>
            Add ("Match (""[dp]"", ""p"", True); Match (""[pq]"", ""q"", True);");
            if Hidden then
               Add ("Match (""[^p]"", ""x"", True); Match (""[^p]"", ""p"", False);");
               Add ("Match (""[Pq]"", ""P"", True); Match (""[\p{digit}]"", ""7"", True);");
               Add ("Match (""[\P{digit}]"", ""a"", True); Match (""[\P{digit}]"", ""7"", False);");
               Add ("Match (""\p{digit}"", ""8"", True); Match (""[a-c]"", ""b"", True);");
               Add ("Check (Regexp.Compile (""[\p{not_a_property}]"").Status /= Regexp.Compile_Ok,"
                    & " ""invalid property"");");
            end if;
         when 5 =>
            Add ("Match (""(ab)\1"", ""abab"", True); Match (""(ab)\1"", ""abac"", False);");
            if Hidden then
               Add ("Match (""(abc)\1"", ""abcabc"", True); Match (""(a|bc)\1"", ""bcbc"", True);");
               Add ("Match (""(ab)(cd)\2\1"", ""abcdcdab"", True); Match (""(ab)+\1"", ""abab"", True);");
               Add ("Match (""[a-z]+"", ""plain"", True); Match (""[a-z]+"", ""123"", False);");
               Add ("Match (""(abc)\1"", ""abcab"", False);");
               Add ("declare C : constant Regexp.Compile_Result := Regexp.Compile (""(ab)\1"");"
                    & " F : Regexp.Match_Result; R : Regexp.Text_Range_Array (1 .. 4); N : Natural; begin");
               Add ("Regexp.Find_From_Planned_With_Captures (C.Expression, ""abab"", 1, F, R, N);");
               Add ("Check (F.Status = Regexp.Match_Ok and then N >= 1 and then R (1).First = 1"
                    & " and then R (1).Last = 2, ""capture span"");");
               Add ("Check (Regexp.Matches_Entire (C.Expression, ""abAB"","
                    & " (Case_Sensitive => True, others => <>)).Status = Regexp.No_Match, ""case option"");");
               Add ("Check (Regexp.Matches_Entire (C.Expression, ""abab"","
                    & " (Max_Steps => 1, others => <>)).Status = Regexp.Match_Limit_Exceeded, ""step limit""); end;");
            end if;
         when 6 =>
            Add ("Check (P.Is_Valid_Ref_Name (""refs/pull/12/head""), ""pull"");");
            Add ("Check (P.Is_Valid_Ref_Name (""vendor/topic""), ""custom"");");
            if Hidden then
               Add ("Check (P.Is_Valid_Ref_Name (""refs/bisect/good""), ""bisect"");");
               Add ("Check (P.Is_Valid_Ref_Name (""refs/heads/main""), ""ordinary"");");
               Add ("Check (not P.Is_Valid_Ref_Name (""single""), ""one level"");");
               Add ("Check (not P.Is_Valid_Ref_Name (""refs/../bad""), ""traversal"");");
               Add ("Check (not P.Is_Valid_Ref_Name (""refs/a.lock""), ""lock"");");
               Add ("Check (not P.Is_Valid_Ref_Name (""refs/a b""), ""space"");");
               Add ("Check (not P.Is_Valid_Ref_Name (""refs/a//b""), ""double slash"");");
               Add ("Check (not P.Is_Valid_Ref_Name (""refs/a@{b""), ""reflog syntax"");");
               Add ("Check (not P.Is_Valid_Ref_Name (""""), ""empty"");");
               Add ("Check (P.Is_Valid_Tag_Name (""v1.0"") and then P.Is_Valid_Remote_Name (""origin""),"
                    & " ""other validators retained"");");
               Add ("Check (P.Is_Valid_Branch_Name (""main""), ""branch retained"");");
            end if;
         when others => null;
      end case;
      return Imports & LF & "with Ada.Strings.Unbounded;" & LF & "procedure " & Unit_Name & " is" & LF
        & "   procedure Check (Good : Boolean; What : String) is" & LF & "   begin" & LF
        & "      if not Good then raise Program_Error with What; end if;" & LF & "   end Check;" & LF
        & Declarations & LF & "begin" & LF & To_String (Checks) & "end " & Unit_Name & ";" & LF;
   end Test_Source;

   procedure Make
     (Root, Workspace : String; Which : Positive; Reference : Boolean; Clean : out Boolean)
   is
      Ran : Hostkit.Process.Process_Outcome;
      Repo : constant String := Workspace & "/" & Repository (Which);
      function Run (Program : String; Words : Hostkit.String_Vectors.Vector; Output : String) return Boolean is
      begin
         Ran := Hostkit.Process.Run_Captured
           (Program, Words, Working_Directory => Root & "/obj",
            Stdout_Path => Output, Stderr_Path => Root & ".prepare-errors", Timeout_Ms => 60_000);
         return Ran.Started and then not Ran.Timed_Out and then Ran.Exit_Status = 0;
      end Run;
      function Git (Words : Hostkit.String_Vectors.Vector; Output : String) return Boolean is
        (Run ("git", [To_Unbounded_String ("-C"), To_Unbounded_String (Repo)] & Words, Output));
      function Init (Words : Hostkit.String_Vectors.Vector) return Boolean is
        (Run ("git", [To_Unbounded_String ("-C"), To_Unbounded_String (Root), To_Unbounded_String ("-c"),
                      To_Unbounded_String ("user.name=held-out fixture"), To_Unbounded_String ("-c"),
                      To_Unbounded_String ("user.email=fixture@example.invalid")] & Words, Hostkit.Fs.Null_Device));
      Smoke : constant String :=
        (if Which = 1 then "with Project_Tools.Text;" elsif Which <= 3 then "with Project_Tools.TOML;"
         elsif Which <= 5 then "with Regexp;" else "with Version.Ref_Names;");
   begin
      Clean := False;
      if Which > Tasks or else Ada.Directories.Exists (Root) then
         return;
      end if;
      Ada.Directories.Create_Path (Root & "/obj");
      if not Git ([To_Unbounded_String ("archive"), To_Unbounded_String ("--format=tar"),
                   To_Unbounded_String (Revision (Which) & "^"), To_Unbounded_String ("src"),
                   To_Unbounded_String ("LICENSE")], Root & ".source.tar")
        or else not Run ("tar", [To_Unbounded_String ("-xf"), To_Unbounded_String (Root & ".source.tar"),
                                To_Unbounded_String ("-C"), To_Unbounded_String (Root)], Hostkit.Fs.Null_Device)
      then
         return;
      end if;
      if Reference then
         for Path of Paths (Which) loop
            if not Git ([To_Unbounded_String ("show"), To_Unbounded_String
                         (Revision (Which) & ":" & To_String (Path))], Root & "/" & To_String (Path))
            then
               return;
            end if;
         end loop;
      end if;
      Project_Tools.Files.Write_Raw_File
        (Root & "/src/main.adb", Smoke & LF & "procedure Main is begin null; end Main;" & LF);
      Project_Tools.Files.Write_Raw_File (Root & "/src/test_add.adb", Test_Source (Which, False));
      Project_Tools.Files.Write_Raw_File (Root & ".hidden_test.adb", Test_Source (Which, True));
      Project_Tools.Files.Write_Raw_File (Root & "/obj/.gitkeep", "");
      Project_Tools.Files.Write_Raw_File
        (Root & "/.gitignore", "obj/*" & LF & "!obj/.gitkeep" & LF & ".model_runner/" & LF & ".trial-runtime/" & LF);
      if not Git ([To_Unbounded_String ("rev-parse"), To_Unbounded_String (Revision (Which) & "^")],
                  Root & ".parent-commit")
        or else not Run ("gnatmake", [To_Unbounded_String ("-q"), To_Unbounded_String ("-gnat2022"),
             To_Unbounded_String ("-D"), To_Unbounded_String (Root & "/obj"),
             To_Unbounded_String ("-aI" & Root & "/src"), To_Unbounded_String (Root & "/src/main.adb"),
             To_Unbounded_String ("-o"), To_Unbounded_String (Root & "/obj/main")], Root & ".smoke")
        or else not Init ([To_Unbounded_String ("init"), To_Unbounded_String ("-q")])
        or else not Init ([To_Unbounded_String ("add"), To_Unbounded_String ("src"), To_Unbounded_String ("LICENSE"),
                           To_Unbounded_String (".gitignore"), To_Unbounded_String ("obj/.gitkeep")])
        or else not Init ([To_Unbounded_String ("commit"), To_Unbounded_String ("-qm"),
                           To_Unbounded_String ("held-out predeclared Ada task")])
      then
         return;
      end if;
      Clean := True;
   exception
      when others => Clean := False;
   end Make;
end Transfer_Curriculum;
