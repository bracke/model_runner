with AUnit.Assertions;

with Model_Runner.Errors;
with Model_Runner.Generation;
with Model_Runner.Localization;
with Model_Runner.Platform;
with Model_Runner.Progress;
with Model_Runner.Text;

package body Tests.Catalog_Cases is

   use AUnit.Assertions;
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
         Loc.Named ("block", "?"),
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
   procedure Pseudo_Locale (T2 : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T2);
      English : Loc.Catalog;
      Pseudo  : Loc.Catalog;
      Checked : Natural := 0;
   begin
      Loc.Open (English, Model_Runner.Platform.Catalog_Path, "en");
      Loc.Open (Pseudo, Model_Runner.Platform.Catalog_Path, "qps");
      Assert (Loc.Is_Ready (English) and then Loc.Is_Ready (Pseudo),
              "the catalog did not load");
      Assert (Loc.Locale (Pseudo) = "qps", "the pseudo-locale did not resolve");

      for Code in E.Error_Code loop
         if Code /= E.No_Error then
            declare
               Key   : constant String := E.Message_Key (Code);
               Plain : constant String :=
                 Loc.Text (English, Key, All_Arguments);
               Fake  : constant String :=
                 Loc.Text (Pseudo, Key, All_Arguments);
            begin
               Assert (Loc.Has (Pseudo, Key),
                       "the pseudo-locale is missing " & Key);
               Assert (Fake /= Plain,
                       Key & " renders identically in the pseudo-locale, so it"
                       & " would hide an untranslated string");

               --  Every placeholder must survive, or the message would lose
               --  the value it was supposed to show.
               Checked := 0;
               for Index in Plain'Range loop
                  if Plain (Index) = '{' then
                     Checked := Checked + 1;
                  end if;
               end loop;

               declare
                  Braces : Natural := 0;
               begin
                  for Index in Fake'Range loop
                     if Fake (Index) = '{' then
                        Braces := Braces + 1;
                     end if;
                  end loop;
                  Assert (Braces = Checked,
                          Key & " lost a placeholder in the pseudo-locale");
               end;
            end;
         end if;
      end loop;

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

   --------------------
   -- Register_Tests --
   --------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Catalog_Loads'Access, "the repository catalog loads and resolves");
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
   end Register_Tests;

end Tests.Catalog_Cases;
