with Model_Runner.CLI.Execute;
with Model_Runner.Errors;
with Model_Runner.Localization;
with Model_Runner.Platform;
with Model_Runner.Presentation;
with Model_Runner.Text;

package body Model_Runner.CLI.Driver is

   use type Model_Runner.CLI.Options.Command_Kind;
   use type Model_Runner.CLI.Options.Prompt_Source;
   use type Model_Runner.CLI.Options.Verbosity;

   package E renames Model_Runner.Errors;
   package Loc renames Model_Runner.Localization;
   package Opt renames Model_Runner.CLI.Options;
   package Pres renames Model_Runner.Presentation;

   --  Environment variables. Names are protocol and are never localized.
   Locale_Variable : constant String := "MODEL_RUNNER_LOCALE";
   Color_Variable  : constant String := "MODEL_RUNNER_COLOR";

   ---------
   -- Run --
   ---------

   procedure Run
     (Source : Opt.Arguments'Class;
      Status : out Natural)
   is
      Catalog : aliased Loc.Catalog;
      Screen  : Pres.Console;
      Item    : Opt.Command;
      Parsed  : E.Error_Info;

      --  Terminal capabilities are read once. Automatic styling is then
      --  decided per destination, so a piped standard output and a terminal
      --  standard error behave correctly at the same time.
      Capabilities : constant Pres.Terminal_Capabilities :=
        (Input_Is_Terminal  => Model_Runner.Platform.Is_Terminal (0),
         Output_Is_Terminal => Model_Runner.Platform.Is_Terminal (1),
         Error_Is_Terminal  => Model_Runner.Platform.Is_Terminal (2),
         Colour_Suppressed  => Model_Runner.Platform.No_Color_Requested);

      --  Styling, resolved from the same narrow scan as the locale so that a
      --  usage error is reported in the requested style.
      function Early_Color return Opt.Color_Mode is
         Found : Boolean;
         Mode  : constant Opt.Color_Mode := Opt.Preliminary_Color (Source, Found);
         From_Environment : constant String :=
           Model_Runner.Platform.Environment_Value (Color_Variable);
      begin
         if Found then
            return Mode;
         elsif From_Environment = "always" then
            return Opt.Color_Always;
         elsif From_Environment = "never" then
            return Opt.Color_Never;
         else
            return Opt.Color_Auto;
         end if;
      end Early_Color;

   begin
      --  Locale first: an ordinary usage error has to be renderable, so the
      --  catalog is resolved before the argument vector is fully parsed.
      Loc.Open
        (Catalog,
         Model_Runner.Platform.Catalog_Path,
         Opt.Preliminary_Locale (Source),
         Model_Runner.Platform.Environment_Value (Locale_Variable),
         Model_Runner.Platform.Host_Locale);

      Pres.Open (Screen, Catalog'Unchecked_Access, Early_Color, Capabilities,
                 Opt.Normal);

      Opt.Parse (Source, Item, Parsed);

      if E.Is_Error (Parsed) then
         Pres.Report (Screen, Parsed);
         Pres.Put_Note (Screen, "diagnostic.hint.usage");
         Opt.Release (Item);
         Loc.Close (Catalog);
         Status := E.Exit_Status (Parsed);
         return;
      end if;

      --  Re-open with the fully parsed presentation settings, and with the
      --  locale the command asked for when it differs from the early scan.
      if not Model_Runner.Text.Is_Empty (Item.Locale) then
         Loc.Open
           (Catalog,
            Model_Runner.Platform.Catalog_Path,
            Model_Runner.Text.To_String (Item.Locale),
            Model_Runner.Platform.Environment_Value (Locale_Variable),
            Model_Runner.Platform.Host_Locale);
      end if;

      Pres.Open
        (Screen, Catalog'Unchecked_Access, Item.Color, Capabilities, Item.Level);

      if not Loc.Is_Ready (Catalog) then
         --  The emergency path: say so once, in the invariant form, and carry
         --  on with message identifiers instead of text.
         Pres.Warn (Screen, "warning.locale_fallback");
      elsif Loc.Used_Fallback (Catalog) and then Item.Level = Opt.Verbose then
         Pres.Warn
           (Screen, "warning.locale_fallback",
            [Loc.Named ("value", Model_Runner.Text.To_String (Item.Locale)),
             Loc.Named ("detail", Loc.Locale (Catalog))]);
      end if;

      --  When no prompt source was given, interactive mode is used only when
      --  both standard input and standard output are terminals; otherwise the
      --  prompt is read from standard input.
      if Item.Kind = Opt.Command_Run
        and then Item.Prompt_Kind = Opt.Prompt_Unset
      then
         if Pres.Supports_Interaction (Capabilities) then
            Item.Prompt_Kind := Opt.Prompt_Interactive;
         else
            Item.Prompt_Kind := Opt.Prompt_Standard_Input;
         end if;
      end if;

      --  Interactive mode asked for by name needs the same terminals it would
      --  have been chosen for. Chosen implicitly it was already conditional on
      --  them; asked for explicitly it was not checked at all, so a redirected
      --  session drew prompts nobody saw and read a file as though someone
      --  were typing it.
      if Item.Kind = Opt.Command_Run
        and then Item.Prompt_Kind = Opt.Prompt_Interactive
        and then not Pres.Supports_Interaction (Capabilities)
      then
         declare
            Condition : constant E.Error_Info :=
              E.Make (E.CLI_Interactive_Unavailable);
         begin
            Pres.Report (Screen, Condition);
            Opt.Release (Item);
            Loc.Close (Catalog);
            Status := E.Exit_Status (Condition);
            return;
         end;
      end if;

      Model_Runner.CLI.Execute.Dispatch (Item, Screen, Catalog, Status);

      Opt.Release (Item);
      Loc.Close (Catalog);
   exception
      --  The outermost boundary. An unexpected exception becomes one concise
      --  internal-failure diagnostic; no traceback reaches the user.
      when others =>
         Opt.Release (Item);
         Pres.Report (Screen, E.Make (E.Internal_Unexpected_Exception));
         Loc.Close (Catalog);
         Status := E.Exit_Internal;
   end Run;

   -----------------
   -- Run_Process --
   -----------------

   procedure Run_Process (Status : out Natural) is
      Source : Opt.Process_Arguments;
   begin
      Run (Source, Status);
   end Run_Process;

end Model_Runner.CLI.Driver;
