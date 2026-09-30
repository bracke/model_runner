with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Fixed;

with Model_Runner.CLI.Execute;
with Model_Runner.Config;
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

   --  The settings file's values become options for a command that takes
   --  them, so this composes them ahead of the command line's own -- an
   --  argument source of the command word, then the file's options a flag
   --  did not already give, then the rest of the arguments as typed.
   package Token_Vectors is
     new Ada.Containers.Indefinite_Vectors (Positive, String);

   type Composed_Arguments
     (Store : access constant Token_Vectors.Vector) is
     new Opt.Arguments with null record;

   overriding function Count (Self : Composed_Arguments) return Natural
   is (Natural (Self.Store.Length));

   overriding function Value
     (Self : Composed_Arguments; Index : Positive) return String
   is (Self.Store.Element (Index));

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

      --  The command line's own arguments composed with the settings file's.
      Tokens : aliased Token_Vectors.Vector;

      --  Whether a setting's key was given on the command line, so the file
      --  does not override a flag the caller typed.
      function On_Command_Line (Name : String) return Boolean is
      begin
         for Index in 2 .. Source.Count loop
            declare
               Arg  : constant String := Source.Value (Index);
               Mark : constant Natural := Ada.Strings.Fixed.Index (Arg, "=");
               Head : constant String :=
                 (if Mark = 0 then Arg else Arg (Arg'First .. Mark - 1));
            begin
               if Head = "--" & Name or else Head = "--no-" & Name then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end On_Command_Line;

      --  Fill Tokens with the command word, the settings the command takes
      --  and the command line did not give (a true/false setting as its
      --  --flag or --no-flag), and the arguments as typed. Left empty when
      --  there is no command word, so the parser sees the source unchanged.
      procedure Compose is
         Kind : Opt.Command_Kind;
         function Lower (Item : String) return String
           renames Ada.Characters.Handling.To_Lower;
         function Truthy (V : String) return Boolean
           is (V = "true" or else V = "yes" or else V = "on");
         function Falsy (V : String) return Boolean
           is (V = "false" or else V = "no" or else V = "off");
      begin
         if Source.Count = 0 then
            return;
         end if;
         Tokens.Append (Source.Value (1));
         Kind := Opt.Command_Of (Source.Value (1));

         for Index in 1 .. Model_Runner.Config.Count loop
            declare
               Key : constant String := Model_Runner.Config.Key_At (Index);
               Val : constant String := Model_Runner.Config.Value_At (Index);
               Low : constant String := Lower (Val);
            begin
               if On_Command_Line (Key) then
                  null;
               elsif Falsy (Low) then
                  if Opt.Accepts (Kind, "--no-" & Key) then
                     Tokens.Append ("--no-" & Key);
                  end if;
               elsif Truthy (Low) then
                  if Opt.Accepts (Kind, "--" & Key) then
                     Tokens.Append ("--" & Key);
                  end if;
               elsif Opt.Accepts (Kind, "--" & Key) then
                  Tokens.Append ("--" & Key);
                  Tokens.Append (Val);
               end if;
            end;
         end loop;

         for Index in 2 .. Source.Count loop
            Tokens.Append (Source.Value (Index));
         end loop;
      end Compose;

      --  Terminal capabilities are read once. Automatic styling is then
      --  decided per destination, so a piped standard output and a terminal
      --  standard error behave correctly at the same time.
      Capabilities : constant Pres.Terminal_Capabilities :=
        (Input_Is_Terminal  => Model_Runner.Platform.Is_Terminal (0),
         Output_Is_Terminal => Model_Runner.Platform.Is_Terminal (1),
         Error_Is_Terminal  => Model_Runner.Platform.Is_Terminal (2),
         Colour_Suppressed  => Model_Runner.Platform.No_Color_Requested);

      --  Report whether the environment asked for a styling this program does
      --  not have a name for.
      --
      --  An unset variable is not an answer and the automatic policy applies.
      --  A variable set to something else is the same mistake as writing
      --  --color=bogus, which is refused, and it was accepted here only
      --  because nothing looked: the value fell through to the automatic
      --  policy and the reader was left believing it had been applied.
      function Environment_Colour_Is_Usable return Boolean is
         Value : constant String :=
           Model_Runner.Platform.Environment_Value (Color_Variable);
      begin
         return Value = "" or else Value = "always" or else Value = "never";
      end Environment_Colour_Is_Usable;

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

      if not Environment_Colour_Is_Usable then
         declare
            Condition : E.Error_Info :=
              E.Make (E.CLI_Invalid_Environment_Value);
         begin
            E.Add_Text
              (Condition, "option", Color_Variable, E.Param_Identifier);
            E.Add_Text
              (Condition, "value",
               Model_Runner.Text.Escape_Controls
                 (Model_Runner.Platform.Environment_Value (Color_Variable)),
               E.Param_Text);
            Pres.Report (Screen, Condition);
            Loc.Close (Catalog);
            Status := E.Exit_Status (Condition);
            return;
         end;
      end if;

      Compose;
      if Tokens.Is_Empty then
         Opt.Parse (Source, Item, Parsed);
      else
         declare
            Composed : Composed_Arguments (Tokens'Access);
         begin
            Opt.Parse (Composed, Item, Parsed);
         end;
      end if;

      if E.Is_Error (Parsed) then
         --  The hint comes from the diagnostic's own recovery class now,
         --  inside Report. Printed here as well it appeared twice.
         Pres.Report (Screen, Parsed);
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
      elsif Loc.Used_Fallback (Catalog)
        and then (Model_Runner.Text.To_String (Item.Locale) /= ""
                  or else Item.Level = Opt.Verbose)
      then
         --  Said whenever the caller named the locale, at any verbosity. A
         --  locale taken from the environment falling back is ordinary and
         --  only worth a word in verbose mode; a locale asked for on the
         --  command line and not honoured is the caller being told their
         --  request was not carried out, and --locale zz said nothing at all.
         Pres.Warn
           (Screen, "warning.locale_fallback",
            [Loc.Named ("value",
                        (if Model_Runner.Text.To_String (Item.Locale) = ""
                         then Loc.Locale (Catalog)
                         else Model_Runner.Text.To_String (Item.Locale))),
             Loc.Named ("detail", Loc.Answering_Locale (Catalog))]);
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
