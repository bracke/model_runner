with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Streams;

with Model_Runner.Bytes;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Limits;

with Tiny_Model;
with Ada.Text_IO;
with AUnit.Assertions;

with Model_Runner.CLI.Options;
with Model_Runner.Errors;
with Model_Runner.Generation;
with Model_Runner.Localization;
with Model_Runner.Platform;
with Model_Runner.Presentation;
with Model_Runner.Progress;
with Model_Runner.Text;

package body Tests.Catalog_Cases is

   use AUnit.Assertions;

   package B renames Model_Runner.Bytes;
   use type B.Byte_Array_Access;
   use type B.Byte_Count;
   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;
   package Gen renames Model_Runner.Generation;
   package Loc renames Model_Runner.Localization;
   package P renames Model_Runner.Progress;
   package T renames Model_Runner.Text;

   --  Every placeholder name the catalog uses. Supplying all of them lets a
   --  completeness check render any message; extra arguments are ignored, and
   --  a message that still fails to render is genuinely missing or malformed.
   All_Arguments : constant Loc.Argument_List :=
     [Loc.Named ("actual", "?"),
         Loc.Named ("alignment", "?"),
         Loc.Named ("architecture", "?"),
         Loc.Named ("available", "?"),
         Loc.Named ("backend", "?"),
         Loc.Named ("block", "?"),
         Loc.Named ("capability", "?"),
         Loc.Named ("capacity", "?"),
         Loc.Named ("category", "?"),
         Loc.Named ("code", "?"),
         Loc.Named ("columns", "?"),
         Loc.Named ("completed", "?"),
         Loc.Named ("construct", "?"),
         Loc.Named ("count", "?"),
         Loc.Named ("detail", "?"),
         Loc.Named ("dimension", "?"),
         Loc.Named ("embedding", "?"),
         Loc.Named ("expected", "?"),
         Loc.Named ("expected_columns", "?"),
         Loc.Named ("expected_rows", "?"),
         Loc.Named ("extra", "?"),
         Loc.Named ("feature", "?"),
         Loc.Named ("field", "?"),
         Loc.Named ("format", "?"),
         Loc.Named ("heads", "?"),
         Loc.Named ("head_size", "?"),
         Loc.Named ("index", "?"),
         Loc.Named ("key", "?"),
         Loc.Named ("kv_heads", "?"),
         Loc.Named ("layer", "?"),
         Loc.Named ("length", "?"),
         Loc.Named ("license", "?"),
         Loc.Named ("limit", "?"),
         Loc.Named ("maximum", "?"),
         Loc.Named ("minimum", "?"),
         Loc.Named ("model", "?"),
         Loc.Named ("name", "?"),
         Loc.Named ("offset", "?"),
         Loc.Named ("option", "?"),
         Loc.Named ("other", "?"),
         Loc.Named ("path", "?"),
         Loc.Named ("placeholder", "?"),
         Loc.Named ("prompt", "?"),
         Loc.Named ("rank", "?"),
         Loc.Named ("requested", "?"),
         Loc.Named ("role", "?"),
         Loc.Named ("rotary", "?"),
         Loc.Named ("rows", "?"),
         Loc.Named ("scaling", "?"),
         Loc.Named ("severity", "?"),
         Loc.Named ("size", "?"),
         Loc.Named ("state", "?"),
         Loc.Named ("supported", "?"),
         Loc.Named ("tensor", "?"),
         Loc.Named ("token", "?"),
         Loc.Named ("total", "?"),
         Loc.Named ("used", "?"),
         Loc.Named ("value", "?"),
         Loc.Named ("version", "?")];

   --  Open the repository catalog for the invariant locale.
   procedure Open (Item : in out Loc.Catalog) is
   begin
      Loc.Open (Item, Model_Runner.Platform.Catalog_Path, "en");
   end Open;

   --  The catalog loads and resolves.
   --  A catalog cannot steer the terminal either.
   --
   --  The message catalog is a file beside the executable, and the
   --  specification counts it among the inputs to treat as untrusted --
   --  alongside model files, prompts and terminal capability data. Its text
   --  goes to a terminal. Values substituted into a message were escaped
   --  because they come from a model file; the message itself was not,
   --  because it comes from the program's own catalog, which is true right
   --  up until somebody replaces the file.
   procedure Catalog_Text_Cannot_Steer_The_Terminal
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Path : constant String := "obj/hostile-catalog.txt";
      ESC  : constant Character := Character'Val (16#1B#);
      BEL  : constant Character := Character'Val (16#07#);

      Handle  : File_Type;
      Catalog : Loc.Catalog;
   begin
      Create (Handle, Out_File, Path);
      Put_Line (Handle, "default_locale = en");

      --  A screen clear in one message and a bell in another, which is what
      --  a hostile catalog would carry: enough to hide what a run reported.
      Put_Line (Handle, "en.application.name = safe" & ESC & "[2Jgone");
      Put_Line (Handle, "en.application.summary = ring" & BEL & "ring");
      Close (Handle);

      Loc.Open (Catalog, Path, "en");
      Assert (Loc.Is_Ready (Catalog), "the hostile catalog did not load");

      declare
         Named   : constant String := Loc.Text (Catalog, "application.name");
         Summary : constant String := Loc.Text (Catalog, "application.summary");

         function Clean (Item : String) return Boolean is
           (for all Char of Item =>
              Character'Pos (Char) >= 16#20#
                and then Character'Pos (Char) /= 16#7F#);
      begin
         Assert (Clean (Named),
                 "an escape sequence from the catalog reached the caller");
         Assert (Clean (Summary),
                 "a bell from the catalog reached the caller");

         --  Escaped rather than dropped, so the text still says what it said
         --  and a reader can see what was in it.
         Assert (Named = "safe\x1B[2Jgone",
                 "the escape was not rendered visibly: " & Named);
         Assert (Summary = "ring\x07ring",
                 "the bell was not rendered visibly: " & Summary);
      end;

      Loc.Close (Catalog);
      Ada.Directories.Delete_File (Path);
   end Catalog_Text_Cannot_Steer_The_Terminal;

   procedure Catalog_Loads (T2 : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T2);
      Catalog : Loc.Catalog;
   begin
      Open (Catalog);
      Assert (Loc.Is_Ready (Catalog),
              "the catalog at " & Model_Runner.Platform.Catalog_Path
              & " did not load");
      Assert (Loc.Locale (Catalog) = "en", "wrong resolved locale");
      Assert (Loc.Text (Catalog, "application.name") = "model_runner",
              "application.name did not render");
      Loc.Close (Catalog);
   end Catalog_Loads;

   --  Quiet suppresses progress, and the other levels do not.
   --
   --  Three guards implement quiet -- on notes, on warnings and on progress
   --  events -- and deleting any of them left every test passing. Two of the
   --  three are only reachable from interactive mode or from a host that
   --  cannot map a file. This one is reachable, and it is the one a run
   --  actually meets: progress is published on every load.
   procedure Quiet_Suppresses_Progress
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      package Opt renames Model_Runner.CLI.Options;
      package P renames Model_Runner.Progress;
      package Pres renames Model_Runner.Presentation;

      Path : constant String := "obj/quiet-progress.txt";

      --  Publish one load event at the given level and return what reached
      --  standard error.
      function Written (Level : Opt.Verbosity) return Natural is
         Catalog  : aliased Loc.Catalog;
         Screen   : aliased Pres.Console;
         Handle   : File_Type;
         Produced : Natural := 0;
      begin
         Loc.Open (Catalog, Model_Runner.Platform.Catalog_Path, "en");

         --  A terminal on standard error, so that the only thing deciding
         --  whether progress appears is the level.
         Pres.Open
           (Screen, Catalog'Unchecked_Access, Opt.Color_Never,
            (Output_Is_Terminal => True,
             Error_Is_Terminal  => True,
             Input_Is_Terminal  => True,
             Colour_Suppressed  => False),
            Level);

         Create (Handle, Out_File, Path);
         Set_Error (Handle);

         declare
            Reporter : aliased Pres.Progress_Reporter (Screen'Unchecked_Access);
         begin
            P.Publish
              (Reporter'Unchecked_Access,
               P.Load_Progress (P.Reading_Metadata, 1, 2));
         end;

         Set_Error (Standard_Error);
         Close (Handle);

         Open (Handle, In_File, Path);
         while not End_Of_File (Handle) loop
            declare
               Line : String (1 .. 400);
               Last : Natural;
            begin
               Get_Line (Handle, Line, Last);
               Produced := Produced + Last + 1;
            end;
         end loop;
         Close (Handle);

         Loc.Close (Catalog);
         return Produced;
      end Written;

      Quietly : constant Natural := Written (Opt.Quiet);
      Plainly : constant Natural := Written (Opt.Normal);
   begin
      Assert (Quietly = 0,
              "quiet wrote" & Natural'Image (Quietly)
              & " bytes of progress");

      --  And the level is what did it: the same event at the ordinary level
      --  is reported, so the check above cannot pass by nothing working.
      Assert (Plainly > 0,
              "the ordinary level wrote no progress, so the quiet case "
              & "proves nothing");

      Ada.Directories.Delete_File (Path);
   end Quiet_Suppresses_Progress;

   --  Every diagnostic code has a message. A code without one would surface as
   --  the emergency form, which is exactly the failure this checks for.
   procedure Every_Code_Resolves (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Catalog : Loc.Catalog;
      Missing : Natural := 0;
   begin
      Open (Catalog);
      Assert (Loc.Is_Ready (Catalog), "the catalog did not load");

      for Code in E.Error_Code loop
         if Code /= E.No_Error then
            declare
               Key : constant String := E.Message_Key (Code);
            begin
               if not Loc.Has (Catalog, Key) then
                  Missing := Missing + 1;
                  Assert (False, "no catalog entry for " & Key);
               end if;

               --  The diagnostic code itself must be well formed and stable.
               Assert (E.Diagnostic_Code (Code)'Length >= 8,
                       "malformed diagnostic code for " & Key);
               Assert (T.Starts_With (E.Diagnostic_Code (Code), "MR-"),
                       "diagnostic code does not start with MR- for " & Key);
            end;
         end if;
      end loop;

      Assert (Missing = 0, "catalog is incomplete");
      Loc.Close (Catalog);
   end Every_Code_Resolves;

   --  Every key the presentation layer derives from an enumeration exists.
   procedure Derived_Keys_Resolve (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Catalog : Loc.Catalog;
   begin
      Open (Catalog);
      Assert (Loc.Is_Ready (Catalog), "the catalog did not load");

      for Stage in P.Load_Stage loop
         declare
            Key : constant String :=
              "progress.loading." & T.To_Lower (P.Load_Stage'Image (Stage));
         begin
            Assert (Loc.Has (Catalog, Key), "no catalog entry for " & Key);
         end;
      end loop;

      for Stage in P.Generation_Stage loop
         declare
            Key : constant String :=
              "progress.generation."
              & T.To_Lower (P.Generation_Stage'Image (Stage));
         begin
            Assert (Loc.Has (Catalog, Key), "no catalog entry for " & Key);
         end;
      end loop;

      for Reason in Gen.Completion_Reason loop
         declare
            Key : constant String := "completion." & Gen.Reason_Name (Reason);
         begin
            Assert (Loc.Has (Catalog, Key), "no catalog entry for " & Key);
         end;
      end loop;

      Loc.Close (Catalog);
   end Derived_Keys_Resolve;

   --  Every key the CLI and the inspect report ask for exists.
   procedure Interface_Keys_Resolve
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Catalog : Loc.Catalog;

      procedure Require (Key : String) is
      begin
         Assert (Loc.Has (Catalog, Key), "no catalog entry for " & Key);
      end Require;
   begin
      Open (Catalog);
      Assert (Loc.Is_Ready (Catalog), "the catalog did not load");

      Require ("application.summary");
      Require ("application.version");
      Require ("application.license");
      Require ("cli.general.usage");
      Require ("cli.general.commands");
      Require ("cli.general.command.run");
      Require ("cli.general.command.inspect");
      Require ("cli.general.command.help");
      Require ("cli.general.command.version");
      Require ("cli.general.exit_statuses");
      Require ("help.run.usage");
      Require ("help.run.summary");
      Require ("help.run.streams");
      Require ("help.run.privacy");
      Require ("help.inspect.usage");
      Require ("help.help.usage");
      Require ("help.version.usage");
      Require ("diagnostic.line");
      Require ("diagnostic.warning_line");
      Require ("diagnostic.note");
      Require ("diagnostic.label.error");
      Require ("diagnostic.label.warning");
      Require ("diagnostic.label.information");
      Require ("diagnostic.label.internal");
      Require ("diagnostic.hint.usage");
      Require ("statistics.heading");
      Require ("statistics.seconds");
      Require ("statistics.per_second");
      Require ("cli.inspect.heading.container");
      Require ("cli.inspect.heading.architecture");
      Require ("cli.inspect.heading.tokenizer");
      Require ("cli.inspect.heading.memory");
      Require ("cli.interactive.banner");
      Require ("cli.interactive.prompt");
      Require ("cli.interactive.help.exit");
      Require ("cli.interactive.help.system");
      Require ("warning.mapping_unavailable");
      Require ("warning.locale_fallback");

      Loc.Close (Catalog);
   end Interface_Keys_Resolve;

   --  Protocol tokens are not translated: the catalog must not redefine a
   --  command name, an option name or an interactive command token.
   procedure Protocol_Tokens_Unchanged
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Catalog : Loc.Catalog;
   begin
      Open (Catalog);
      Assert (Loc.Is_Ready (Catalog), "the catalog did not load");

      --  The interactive command tokens appear inside their own help lines and
      --  must survive translation verbatim.
      Assert
        (T.Starts_With (Loc.Text (Catalog, "cli.interactive.help.exit"), "/exit"),
         "the /exit token was translated");
      Assert
        (T.Starts_With
           (Loc.Text (Catalog, "cli.interactive.help.reset"), "/reset"),
         "the /reset token was translated");
      Assert
        (T.Starts_With
           (Loc.Text (Catalog, "cli.interactive.help.system"), "/system"),
         "the /system token was translated");

      --  Option names appear in help lines and are likewise protocol.
      Assert
        (T.Starts_With (Loc.Text (Catalog, "help.run.prompt"), "--prompt"),
         "the --prompt option name was translated");
      Assert
        (T.Starts_With (Loc.Text (Catalog, "help.run.seed"), "--seed"),
         "the --seed option name was translated");

      Loc.Close (Catalog);
   end Protocol_Tokens_Unchanged;

   --  A missing catalog, a missing key and a broken catalog all fall back to
   --  the emergency form rather than failing or recursing.
   procedure Emergency_Path (T2 : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T2);
      Catalog : Loc.Catalog;
   begin
      --  A catalog that is not there.
      Loc.Open (Catalog, "does/not/exist/catalog.txt", "en");
      Assert (not Loc.Is_Ready (Catalog),
              "a missing catalog was reported as ready");
      Assert (Loc.Text (Catalog, "application.name") = "<application.name>",
              "a missing catalog did not use the emergency form");
      Loc.Close (Catalog);

      --  A key that is not there.
      Open (Catalog);
      Assert (Loc.Is_Ready (Catalog), "the catalog did not load");
      Assert (Loc.Text (Catalog, "no.such.key") = "<no.such.key>",
              "a missing key did not use the emergency form");
      Assert (not Loc.Has (Catalog, "no.such.key"),
              "a missing key was reported as present");
      Loc.Close (Catalog);
   end Emergency_Path;

   --  A locale that the catalog does not carry falls back and says so.
   procedure Locale_Fallback (T2 : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T2);
      Catalog : Loc.Catalog;
   begin
      Loc.Open (Catalog, Model_Runner.Platform.Catalog_Path, "zz");
      Assert (Loc.Is_Ready (Catalog), "the catalog did not load");
      Assert (Loc.Used_Fallback (Catalog),
              "an unavailable locale did not report a fallback");
      Assert (Loc.Text (Catalog, "application.name") = "model_runner",
              "the fallback locale did not render");
      Loc.Close (Catalog);

      --  A host locale in POSIX form is normalized before it is resolved.
      Loc.Open (Catalog, Model_Runner.Platform.Catalog_Path, "en_US.UTF-8");
      Assert (Loc.Is_Ready (Catalog), "the catalog did not load");
      Assert (Loc.Text (Catalog, "application.name") = "model_runner",
              "a POSIX host locale was not normalized");
      Loc.Close (Catalog);
   end Locale_Fallback;

   --  A structured condition renders with its typed parameters substituted,
   --  and untrusted parameter values are escaped.
   procedure Conditions_Render (T2 : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T2);
      Catalog   : Loc.Catalog;
      Condition : E.Error_Info := E.Make (E.CLI_Unknown_Option);
   begin
      Open (Catalog);
      Assert (Loc.Is_Ready (Catalog), "the catalog did not load");

      E.Add_Text (Condition, "option", "--nope", E.Param_Identifier);
      Assert (Loc.Describe (Catalog, Condition) = "unknown option: --nope",
              "rendered """ & Loc.Describe (Catalog, Condition) & """");

      --  A value carrying a terminal escape must not reach the terminal as
      --  one.
      declare
         Hostile : E.Error_Info := E.Make (E.GGUF_Duplicate_Tensor_Name);
      begin
         E.Add_Text
           (Hostile, "tensor", ASCII.ESC & "[31mred", E.Param_Identifier);
         declare
            Rendered : constant String := Loc.Describe (Catalog, Hostile);
         begin
            Assert (not T.Has_Controls (Rendered),
                    "a control character survived into a diagnostic");
         end;
      end;

      Loc.Close (Catalog);
   end Conditions_Render;

   --  The pseudo-locale exists, differs from English everywhere, and keeps
   --  every placeholder and protocol token intact. That is what makes it
   --  useful: a message that renders unchanged is one that bypassed the
   --  catalog.
   --
   --  Every English key, not the diagnostics alone. This walked Error_Code
   --  and so covered 148 of 343 keys; the 195 it skipped -- help, inspect,
   --  statistics, interactive, progress -- are the ones a reader sees most,
   --  and they are exactly where a string that never went through the
   --  catalog would hide. Ten dead keys sat in that gap, translated into
   --  three locales, until something else found them.
   --
   --  The keys are read from the catalog file rather than asked of the
   --  runtime, because there is no operation that enumerates them and one
   --  added for a test would be a registry of its own.
   procedure Pseudo_Locale (T2 : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T2);

      Room  : constant := 512;
      Width : constant := 96;

      type Key_Text is record
         Text : String (1 .. Width) := [others => ' '];
         Last : Natural := 0;
      end record;

      English : Loc.Catalog;
      Pseudo  : Loc.Catalog;
      Held    : array (1 .. Room) of Key_Text;
      Count   : Natural := 0;
      Walked  : Natural := 0;

      --  Catalog_Path names the file, not the directory holding it.
      File : constant String := Model_Runner.Platform.Catalog_Path;

      --  The key of a catalog line in the named locale, or empty.
      function Key_Of (Line, Locale : String) return String is
         Prefix : constant String := Locale & ".";
      begin
         if Line'Length <= Prefix'Length
           or else Line (Line'First .. Line'First + Prefix'Length - 1) /= Prefix
         then
            return "";
         end if;
         for Index in Line'First + Prefix'Length .. Line'Last loop
            if Line (Index) = ' ' then
               return Line (Line'First + Prefix'Length .. Index - 1);
            end if;
         end loop;
         return "";
      end Key_Of;

      --  Count the placeholders of a rendered message.
      function Braces (Text : String) return Natural is
         Total : Natural := 0;
      begin
         for Index in Text'Range loop
            if Text (Index) = '{' then
               Total := Total + 1;
            end if;
         end loop;
         return Total;
      end Braces;

      Source : Ada.Text_IO.File_Type;
   begin
      Loc.Open (English, Model_Runner.Platform.Catalog_Path, "en");
      Loc.Open (Pseudo, Model_Runner.Platform.Catalog_Path, "qps");
      Assert (Loc.Is_Ready (English) and then Loc.Is_Ready (Pseudo),
              "the catalog did not load");
      Assert (Loc.Locale (Pseudo) = "qps", "the pseudo-locale did not resolve");

      Ada.Text_IO.Open (Source, Ada.Text_IO.In_File, File);
      while not Ada.Text_IO.End_Of_File (Source) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (Source);
            Key  : constant String := Key_Of (Line, "en");
         begin
            if Key /= "" then
               declare
                  Plain : constant String :=
                    Loc.Text (English, Key, All_Arguments);
                  Fake  : constant String :=
                    Loc.Text (Pseudo, Key, All_Arguments);
               begin
                  Assert (Loc.Has (Pseudo, Key),
                          "the pseudo-locale is missing " & Key);
                  Assert (Fake /= Plain,
                          Key & " renders identically in the pseudo-locale, so"
                          & " it would hide an untranslated string");
                  Assert (Braces (Fake) = Braces (Plain),
                          Key & " lost a placeholder in the pseudo-locale");
                  Walked := Walked + 1;

                  if Count < Room and then Key'Length <= Width then
                     Count := Count + 1;
                     Held (Count).Last := Key'Length;
                     Held (Count).Text (1 .. Key'Length) := Key;
                  end if;
               end;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (Source);

      Assert (Walked > 300,
              "the catalog walk found" & Natural'Image (Walked)
              & " English keys, so it no longer matches the file it reads");

      --  And nothing the other way: a pseudo-localized message whose English
      --  original is gone is a translation of something nobody can ask for.
      Ada.Text_IO.Open (Source, Ada.Text_IO.In_File, File);
      while not Ada.Text_IO.End_Of_File (Source) loop
         declare
            Line  : constant String := Ada.Text_IO.Get_Line (Source);
            Key   : constant String := Key_Of (Line, "qps");
            Known : Boolean := False;
         begin
            if Key /= "" then
               for Index in 1 .. Count loop
                  if Held (Index).Text (1 .. Held (Index).Last) = Key then
                     Known := True;
                  end if;
               end loop;
               Assert (Known,
                       "the pseudo-locale carries " & Key
                       & ", which English does not have");
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (Source);

      --  Protocol tokens survive pseudo-localization.
      declare
         --  U+27E6 MATHEMATICAL LEFT WHITE SQUARE BRACKET, the marker the
         --  pseudo-locale wraps every message in. Spelled by its bytes rather
         --  than as a literal: the sources are compiled as UTF-8, where a
         --  character literal outside Latin-1 is not a Standard.Character.
         Marker : constant String :=
           [Character'Val (16#E2#), Character'Val (16#9F#),
            Character'Val (16#A6#)];
      begin
         Assert
           (T.Starts_With (Loc.Text (Pseudo, "cli.interactive.help.exit"),
                           Marker & "/exit"),
            "the /exit token was altered by the pseudo-locale");
      end;

      Loc.Close (English);
      Loc.Close (Pseudo);
   end Pseudo_Locale;

   --  A real second locale renders its own messages and inherits the rest,
   --  which is what makes a partial translation usable.
   procedure Second_Locale (T2 : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T2);
      Danish  : Loc.Catalog;
      English : Loc.Catalog;
      Own     : Natural := 0;
      Shared  : Natural := 0;
   begin
      Loc.Open (Danish, Model_Runner.Platform.Catalog_Path, "da");
      Loc.Open (English, Model_Runner.Platform.Catalog_Path, "en");
      Assert (Loc.Is_Ready (Danish), "the catalog did not load");
      Assert (Loc.Locale (Danish) = "da", "the requested locale was discarded");

      --  Messages the translation carries are translated.
      Assert (Loc.Text (Danish, "diagnostic.label.error") = "fejl",
              "a translated label was not used");
      Assert (Loc.Text (Danish, "cli.inspect.heading.container") = "Beholder",
              "a translated heading was not used");

      --  Every key still renders, translated or inherited, and nothing falls
      --  through to the emergency form.
      for Code in E.Error_Code loop
         if Code /= E.No_Error then
            declare
               Key  : constant String := E.Message_Key (Code);
               Text : constant String := Loc.Text (Danish, Key, All_Arguments);
            begin
               Assert (Text /= "<" & Key & ">",
                       Key & " reached the emergency form in Danish");
               if Text = Loc.Text (English, Key, All_Arguments) then
                  Shared := Shared + 1;
               else
                  Own := Own + 1;
               end if;
            end;
         end if;
      end loop;

      Assert (Own > 0, "the second locale translated nothing");
      Assert (Shared > 0,
              "the second locale is complete, so per-key fallback is untested");

      Loc.Close (Danish);
      Loc.Close (English);
   end Second_Locale;

   --  A POSIX host locale is normalized before it is resolved.
   procedure Host_Locale_Normalized
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Catalog : Loc.Catalog;
   begin
      Loc.Open (Catalog, Model_Runner.Platform.Catalog_Path, "da_DK.UTF-8");
      Assert (Loc.Is_Ready (Catalog), "the catalog did not load");
      Assert (Loc.Text (Catalog, "diagnostic.label.error") = "fejl",
              "a POSIX host locale did not resolve to its language");
      Loc.Close (Catalog);
   end Host_Locale_Normalized;

   ----------
   -- Name --
   ----------

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("message catalog");
   end Name;

   --  No two progress stages say the same thing.
   --
   --  Progress lines print one after another, so two stages with the same text
   --  read as one line repeated rather than as two things happening. That is
   --  what "generated 4 tokens" printed twice was: the last token and the end
   --  of generation carried identical wording, and the reader saw a stutter.
   --
   --  Only the progress family is checked. Elsewhere two keys saying the same
   --  thing is ordinary -- the same option is described under two commands,
   --  the same label serves the interactive settings and the statistics -- and
   --  those never appear side by side.
   procedure Progress_Stages_Read_Distinctly
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package P renames Model_Runner.Progress;

      Catalog : Loc.Catalog;

      Count : constant Natural :=
        P.Load_Stage'Pos (P.Load_Stage'Last) + 1
        + P.Generation_Stage'Pos (P.Generation_Stage'Last) + 1;

      Seen  : array (1 .. Count) of Model_Runner.Text.Bounded :=
        [others => Model_Runner.Text.Empty];
      Names : array (1 .. Count) of Model_Runner.Text.Bounded :=
        [others => Model_Runner.Text.Empty];
      Used  : Natural := 0;

      --  Render one stage and check it against everything rendered so far.
      procedure Take (Key : String) is
         --  The arguments a progress line may carry. Both are supplied so a
         --  message that uses either still renders.
         Line : constant String :=
           Loc.Text
             (Catalog, Key,
              [Loc.Named ("completed", "7"), Loc.Named ("total", "9")]);
      begin
         Assert (Line /= "<" & Key & ">",
                 "progress stage " & Key & " has no message");

         for Index in 1 .. Used loop
            Assert (Model_Runner.Text.To_String (Seen (Index)) /= Line,
                    "progress stages "
                    & Model_Runner.Text.To_String (Names (Index))
                    & " and " & Key & " both read " & Line);
         end loop;

         Used := Used + 1;
         Seen (Used) := Model_Runner.Text.To_Bounded (Line);
         Names (Used) := Model_Runner.Text.To_Bounded (Key);
      end Take;
   begin
      Open (Catalog);

      for Stage in P.Load_Stage loop
         Take ("progress.loading."
               & Model_Runner.Text.To_Lower (P.Load_Stage'Image (Stage)));
      end loop;

      for Stage in P.Generation_Stage loop
         Take ("progress.generation."
               & Model_Runner.Text.To_Lower (P.Generation_Stage'Image (Stage)));
      end loop;

      Assert (Used = Count, "not every progress stage was checked");
      Loc.Close (Catalog);
   end Progress_Stages_Read_Distinctly;

   --------------------
   -- Register_Tests --
   --------------------

   ----------------------------------------
   -- Real_Diagnostics_Render_In_Full --
   ----------------------------------------

   --  Every diagnostic a broken file produces must be a sentence.
   --
   --  When a message names a value nothing attaches, the catalog cannot
   --  render it and the reader falls back to printing the key in angle
   --  brackets. That is what a user saw for every truncated model file --
   --  the commonest way a file is wrong -- because the message says "at
   --  offset {offset}" and the reader recorded the offset as technical
   --  context rather than as a value the message could name.
   --
   --  The repository check that was meant to catch it could not: it asks
   --  whether anything anywhere attaches a value of that name, and the
   --  reader does attach one, for a different diagnostic. So this asks the
   --  question the other way round, by breaking a file in many places and
   --  requiring that whatever comes back renders.

   procedure Real_Diagnostics_Render_In_Full
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Whole : constant String := "obj/render-whole.gguf";
      Cut   : constant String := "obj/render-cut.gguf";

      Catalog : Loc.Catalog;
      Checked : Natural := 0;

      --  Read the fixture once, so the truncations are of a real container.
      function Bytes_Of (Path : String) return B.Byte_Array_Access is
         use Ada.Streams.Stream_IO;
         Handle : File_Type;
         Result : B.Byte_Array_Access;
         Size   : Ada.Directories.File_Size;
      begin
         Size := Ada.Directories.Size (Path);
         B.Allocate (B.Byte_Count (Size), Result);
         if Result = null then
            return null;
         end if;
         Open (Handle, In_File, Path);
         declare
            Buffer : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Size));
            Last   : Ada.Streams.Stream_Element_Offset;
         begin
            Ada.Streams.Read (Stream (Handle).all, Buffer, Last);
            for Index in 1 .. Last loop
               Result.all (Result.all'First + B.Byte_Count (Index) - 1) :=
                 B.Byte (Buffer (Index));
            end loop;
         end;
         Close (Handle);
         return Result;
      end Bytes_Of;

      Source : B.Byte_Array_Access;
   begin
      Tiny_Model.Write (Whole);
      Source := Bytes_Of (Whole);
      Assert (Source /= null, "could not read the fixture");

      Loc.Open (Catalog, Model_Runner.Platform.Catalog_Path, "en");
      Assert (Loc.Is_Ready (Catalog), "the catalog did not open");

      --  Cut the file at a spread of places. Each cut lands in a different
      --  part of the container -- the header, the metadata, the tensor
      --  descriptors -- so the refusals differ.
      for Step in 1 .. 40 loop
         declare
            Keep : constant B.Byte_Count :=
              B.Byte_Count (Step) * B.Byte_Count (Source.all'Length / 41);
            use Ada.Streams.Stream_IO;
            Handle : File_Type;
         begin
            Create (Handle, Out_File, Cut);
            for Index in 0 .. Keep - 1 loop
               Ada.Streams.Stream_Element'Write
                 (Stream (Handle),
                  Ada.Streams.Stream_Element
                    (Source.all (Source.all'First + Index)));
            end loop;
            Close (Handle);

            declare
               Reader_Source : Model_Runner.Byte_Sources.Files.File_Source;
               Item          : Model_Runner.GGUF.Containers.Container;
               Status        : E.Error_Info;
               Opening       : E.Error_Info;
            begin
               Model_Runner.Byte_Sources.Files.Open
                 (Reader_Source, Cut, Status => Opening);
               if not E.Is_Error (Opening) then
                  Model_Runner.GGUF.Containers.Reader.Parse
                    (Item, Reader_Source,
                     Model_Runner.Limits.Default_Model_Limits,
                     null, null, Status);

                  if E.Is_Error (Status) then
                     declare
                        Said : constant String := Loc.Describe (Catalog, Status);
                     begin
                        Checked := Checked + 1;
                        Assert (Said'Length > 0
                                and then Said (Said'First) /= '<',
                                "a truncation at" & B.Byte_Count'Image (Keep)
                                & " bytes rendered as " & Said);
                     end;
                  else
                     Model_Runner.GGUF.Containers.Close (Item);
                  end if;
                  Model_Runner.Byte_Sources.Files.Close (Reader_Source);
               end if;
            end;
         end;
      end loop;

      B.Free (Source);
      Loc.Close (Catalog);

      Assert (Checked >= 20,
              "only" & Natural'Image (Checked) & " truncations were refused, "
              & "so this checked far less than it looks");
   end Real_Diagnostics_Render_In_Full;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Progress_Stages_Read_Distinctly'Access,
         "no two progress stages say the same thing");
      Register_Routine
        (T, Catalog_Loads'Access, "the repository catalog loads and resolves");
      Register_Routine
        (T, Quiet_Suppresses_Progress'Access,
         "quiet suppresses progress and the ordinary level does not");
      Register_Routine
        (T, Catalog_Text_Cannot_Steer_The_Terminal'Access,
         "a catalog cannot steer the terminal either");
      Register_Routine
        (T, Every_Code_Resolves'Access,
         "every diagnostic code has a catalog entry");
      Register_Routine
        (T, Derived_Keys_Resolve'Access,
         "every key derived from an enumeration has a catalog entry");
      Register_Routine
        (T, Interface_Keys_Resolve'Access,
         "every key the command line and inspect ask for exists");
      Register_Routine
        (T, Protocol_Tokens_Unchanged'Access,
         "command and option tokens are not translated");
      Register_Routine
        (T, Emergency_Path'Access,
         "a missing catalog or key falls back to the emergency form");
      Register_Routine
        (T, Locale_Fallback'Access,
         "an unavailable locale falls back and reports it");
      Register_Routine
        (T, Conditions_Render'Access,
         "structured conditions render with escaped parameters");
      Register_Routine
        (T, Pseudo_Locale'Access,
         "the pseudo-locale differs everywhere and keeps placeholders");
      Register_Routine
        (T, Second_Locale'Access,
         "a partial second locale translates and inherits per key");
      Register_Routine
        (T, Host_Locale_Normalized'Access,
         "a POSIX host locale resolves to its language");

      Register_Routine
        (T, Real_Diagnostics_Render_In_Full'Access,
         "a diagnostic from a broken file renders as a sentence rather than "
         & "as its own message key");
   end Register_Tests;

end Tests.Catalog_Cases;
