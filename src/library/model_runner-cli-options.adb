with Ada.Command_Line;
with Ada.Unchecked_Deallocation;

with Model_Runner.Numerics;
with Model_Runner.Templates;

package body Model_Runner.CLI.Options is

   --  Every option, the commands that take it, and the help line that
   --  documents it.
   --
   --  Three answers to one question used to be given separately: what the
   --  parser accepts, what a command may be given, and what the help screens
   --  list. The parser accepted everything for every command -- `inspect
   --  m.gguf --temperature 0.5 --interactive` ran the inspection and said
   --  nothing -- and the help lists were written out beside it, so `inspect`
   --  documented five options while thirty-seven were reachable, and --quiet
   --  and --verbose worked there while appearing only under run.
   type Entry_Text is access constant String;

   type Registry_Row is record
      Name  : Entry_Text;
      Where : Command_Set;
      Help  : Entry_Text;
   end record;

   --  A literal on the heap, so the table can be written flat. Allocated at
   --  elaboration and never released, which is what a table of constants is.
   function Text (Value : String) return Entry_Text
   is (new String'(Value));

   Registry : constant array (1 .. 37) of Registry_Row :=
     [
      (Text ("--prompt"), [Command_Run => True, others => False], Text ("prompt")),
      (Text ("--prompt-file"), [Command_Run => True, others => False], Text ("prompt_file")),
      (Text ("--interactive"), [Command_Run => True, others => False], Text ("interactive")),
      (Text ("--raw"), [Command_Run => True, others => False], Text ("raw")),
      (Text ("--system"), [Command_Run => True, others => False], Text ("system")),
      (Text ("--system-file"), [Command_Run => True, others => False], Text ("system_file")),
      (Text ("--max-tokens"), [Command_Run => True, others => False], Text ("max_tokens")),
      (Text ("--context-size"), [Command_Run => True, others => False], Text ("context_size")),
      (Text ("--threads"),
       [Command_Run | Command_Inspect => True, others => False],
       Text ("threads")),
      (Text ("--backend"),
       [Command_Run | Command_Inspect => True, others => False],
       Text ("backend")),
      (Text ("--batch-size"), [Command_Run => True, others => False], Text ("batch_size")),
      (Text ("--temperature"), [Command_Run => True, others => False], Text ("temperature")),
      (Text ("--top-k"), [Command_Run => True, others => False], Text ("top_k")),
      (Text ("--top-p"), [Command_Run => True, others => False], Text ("top_p")),
      (Text ("--min-p"), [Command_Run => True, others => False], Text ("min_p")),
      (Text ("--chat-template"), [Command_Run => True, others => False], Text ("chat_template")),
      (Text ("--repeat-penalty"), [Command_Run => True, others => False], Text ("repeat_penalty")),
      (Text ("--frequency-penalty"), [Command_Run => True, others => False], Text ("frequency_penalty")),
      (Text ("--presence-penalty"), [Command_Run => True, others => False], Text ("presence_penalty")),
      (Text ("--repeat-window"), [Command_Run => True, others => False], Text ("repeat_window")),
      (Text ("--seed"), [Command_Run => True, others => False], Text ("seed")),
      (Text ("--stop"), [Command_Run => True, others => False], Text ("stop")),
      (Text ("--stop-token"), [Command_Run => True, others => False], Text ("stop_token")),
      (Text ("--memory-limit"), [Command_Run => True, others => False], Text ("memory_limit")),
      (Text ("--mmap"), [Command_Run => True, others => False], Text ("mmap")),
      (Text ("--no-mmap"), [Command_Run => True, others => False], Text ("no_mmap")),
      (Text ("--show-stats"), [Command_Run => True, others => False], Text ("show_stats")),
      (Text ("--no-stats"), [Command_Run => True, others => False], Text ("no_stats")),
      (Text ("--metadata"), [Command_Inspect => True, others => False], Text ("metadata")),
      (Text ("--tensors"), [Command_Inspect => True, others => False], Text ("tensors")),
      (Text ("--validate"), [Command_Inspect => True, others => False], Text ("validate")),
      (Text ("--quiet"), [others => True], Text ("quiet")),
      (Text ("--verbose"), [others => True], Text ("verbose")),
      (Text ("--locale"), [others => True], Text ("locale")),
      (Text ("--color"), [others => True], Text ("color")),
      (Text ("--help"), [others => True], Text ("")),
      (Text ("--version"), [others => True], Text (""))];

   ------------------
   -- Option_Count --
   ------------------

   function Option_Count return Natural is (Registry'Length);

   -----------------
   -- Option_Name --
   -----------------

   function Option_Name (Index : Positive) return String
   is (Registry (Index).Name.all);

   ---------------------
   -- Option_Commands --
   ---------------------

   function Option_Commands (Index : Positive) return Command_Set
   is (Registry (Index).Where);

   -----------------
   -- Option_Help --
   -----------------

   function Option_Help (Index : Positive) return String
   is (Registry (Index).Help.all);

   ------------------
   -- Command_Word --
   ------------------

   --  The word a caller types for a command. Never localized: it is
   --  protocol, and a diagnostic naming a translated command word tells the
   --  reader to type something the parser will refuse.
   function Command_Word (Kind : Command_Kind) return String
   is (case Kind is
         when Command_None    => "",
         when Command_Run     => "run",
         when Command_Inspect => "inspect",
         when Command_Help    => "help",
         when Command_Version => "version");

   -------------
   -- Accepts --
   -------------

   function Accepts (Kind : Command_Kind; Name : String) return Boolean is
   begin
      for Row of Registry loop
         if Row.Name.all = Name then
            return Row.Where (Kind);
         end if;
      end loop;

      --  A name no row holds is not an option this program has, which the
      --  parser reports for itself.
      return False;
   end Accepts;

   use type Interfaces.Unsigned_64;
   use type Model_Runner.Numerics.Real;

   package E renames Model_Runner.Errors;
   package Files renames Model_Runner.Byte_Sources.Files;
   package T renames Model_Runner.Text;

   procedure Free_Text is new Ada.Unchecked_Deallocation (String, Text_Access);

   -------------
   -- Count --
   -------------

   overriding function Count (Self : Process_Arguments) return Natural is
      pragma Unreferenced (Self);
   begin
      return Ada.Command_Line.Argument_Count;
   end Count;

   -------------
   -- Value --
   -------------

   overriding function Value
     (Self : Process_Arguments; Index : Positive) return String
   is
      pragma Unreferenced (Self);
   begin
      return Ada.Command_Line.Argument (Index);
   end Value;

   -------------
   -- Release --
   -------------

   -----------------
   -- Color_Names --
   -----------------

   function Color_Names return String is
      Room : String (1 .. 128);
      Used : Natural := 0;

      procedure Add (Text : String) is
      begin
         if Used + Text'Length <= Room'Length then
            Room (Used + 1 .. Used + Text'Length) := Text;
            Used := Used + Text'Length;
         end if;
      end Add;
   begin
      for Mode in Color_Mode loop
         if Used > 0 then
            Add (", ");
         end if;
         Add (Color_Name (Mode));
      end loop;
      return Room (1 .. Used);
   end Color_Names;

   procedure Release (Item : in out Command) is
   begin
      if Item.Prompt_Text /= null then
         --  Prompt text may be sensitive; clear it before releasing.
         Item.Prompt_Text.all := [others => ' '];
         Free_Text (Item.Prompt_Text);
      end if;
      if Item.System_Text /= null then
         Item.System_Text.all := [others => ' '];
         Free_Text (Item.System_Text);
      end if;
   end Release;

   --  Split "--name=value" into its parts. Value_Present is False for a bare
   --  "--name".
   procedure Split
     (Argument      : String;
      Name_Last     : out Natural;
      Value_First   : out Natural;
      Value_Present : out Boolean) is
   begin
      Name_Last := Argument'Last;
      Value_First := Argument'Last + 1;
      Value_Present := False;

      for Index in Argument'Range loop
         if Argument (Index) = '=' then
            Name_Last := Index - 1;
            Value_First := Index + 1;
            Value_Present := True;
            return;
         end if;
      end loop;
   end Split;

   --  Parse a non-negative integer, rejecting anything else.
   procedure To_Number
     (Text  : String;
      Value : out Long_Long_Integer;
      Ok    : out Boolean)
   is
      Result   : Long_Long_Integer := 0;
      Negative : Boolean := False;
      First    : Natural := Text'First;
   begin
      Value := 0;
      Ok := False;

      if Text'Length = 0 then
         return;
      end if;

      if Text (First) = '-' then
         Negative := True;
         First := First + 1;
      elsif Text (First) = '+' then
         First := First + 1;
      end if;

      if First > Text'Last then
         return;
      end if;

      for Index in First .. Text'Last loop
         if Text (Index) not in '0' .. '9' then
            return;
         end if;
         if Result > (Long_Long_Integer'Last - 9) / 10 then
            return;
         end if;
         Result :=
           Result * 10
           + Long_Long_Integer (Character'Pos (Text (Index)) - Character'Pos ('0'));
      end loop;

      Value := (if Negative then -Result else Result);
      Ok := True;
   end To_Number;

   --  Parse an unsigned decimal number covering the whole 64-bit range.
   --
   --  A seed is an unsigned 64-bit value and the program generates one across
   --  that whole range. Parsing it into a signed type rejected every seed
   --  above Long_Long_Integer'Last, so a run whose seed came out of the upper
   --  half could not be reproduced with --seed -- which is the one thing the
   --  option is for.
   procedure To_Unsigned
     (Text  : String;
      Value : out Interfaces.Unsigned_64;
      Ok    : out Boolean)
   is
      Limit  : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64'Last;
      Result : Interfaces.Unsigned_64 := 0;
      Digit  : Interfaces.Unsigned_64;
      First  : Natural := Text'First;
   begin
      Value := 0;
      Ok := False;

      if Text'Length = 0 then
         return;
      end if;

      if Text (First) = '+' then
         First := First + 1;
      end if;

      if First > Text'Last then
         return;
      end if;

      for Index in First .. Text'Last loop
         if Text (Index) not in '0' .. '9' then
            return;
         end if;

         Digit :=
           Interfaces.Unsigned_64
             (Character'Pos (Text (Index)) - Character'Pos ('0'));

         --  Checked before multiplying rather than after: the type wraps
         --  silently, so an overflowed value would look like a valid seed.
         if Result > (Limit - Digit) / 10 then
            return;
         end if;

         Result := Result * 10 + Digit;
      end loop;

      Value := Result;
      Ok := True;
   end To_Unsigned;

   --  Parse a decimal number. Deliberately not locale-aware: an option value
   --  is protocol, not presentation.
   procedure To_Real
     (Text  : String;
      Value : out Model_Runner.Numerics.Real;
      Ok    : out Boolean)
   is
      Whole      : Long_Long_Integer := 0;
      Fraction   : Long_Long_Integer := 0;
      Divisor    : Long_Long_Integer := 1;
      Negative   : Boolean := False;
      Seen_Digit : Boolean := False;
      Seen_Point : Boolean := False;
      Index      : Natural := Text'First;
   begin
      Value := 0.0;
      Ok := False;

      if Text'Length = 0 then
         return;
      end if;

      if Text (Index) = '-' then
         Negative := True;
         Index := Index + 1;
      elsif Text (Index) = '+' then
         Index := Index + 1;
      end if;

      while Index <= Text'Last loop
         if Text (Index) = '.' then
            if Seen_Point then
               return;
            end if;
            Seen_Point := True;
         elsif Text (Index) in '0' .. '9' then
            Seen_Digit := True;
            declare
               Digit : constant Long_Long_Integer :=
                 Long_Long_Integer
                   (Character'Pos (Text (Index)) - Character'Pos ('0'));
            begin
               if Seen_Point then
                  if Divisor <= Long_Long_Integer'Last / 10 then
                     Fraction := Fraction * 10 + Digit;
                     Divisor := Divisor * 10;
                  end if;
               else
                  if Whole > (Long_Long_Integer'Last - 9) / 10 then
                     return;
                  end if;
                  Whole := Whole * 10 + Digit;
               end if;
            end;
         else
            return;
         end if;
         Index := Index + 1;
      end loop;

      if not Seen_Digit then
         return;
      end if;

      Value := Model_Runner.Numerics.Real (Whole)
        + Model_Runner.Numerics.Real (Fraction)
          / Model_Runner.Numerics.Real (Divisor);
      if Negative then
         Value := -Value;
      end if;
      Ok := True;
   end To_Real;

   --  Parse a byte size with an optional K, M or G suffix.
   procedure To_Bytes
     (Text  : String;
      Value : out Interfaces.Unsigned_64;
      Ok    : out Boolean)
   is
      Multiplier : Interfaces.Unsigned_64 := 1;
      Last       : Natural := Text'Last;
      Number     : Long_Long_Integer;
   begin
      Value := 0;
      Ok := False;

      if Text'Length = 0 then
         return;
      end if;

      case Text (Last) is
         when 'k' | 'K' => Multiplier := 1024;             Last := Last - 1;
         when 'm' | 'M' => Multiplier := 1024 ** 2;        Last := Last - 1;
         when 'g' | 'G' => Multiplier := 1024 ** 3;        Last := Last - 1;
         when others    => null;
      end case;

      To_Number (Text (Text'First .. Last), Number, Ok);
      if not Ok or else Number < 0 then
         Ok := False;
         return;
      end if;

      if Interfaces.Unsigned_64 (Number) > Interfaces.Unsigned_64'Last / Multiplier
      then
         Ok := False;
         return;
      end if;

      Value := Interfaces.Unsigned_64 (Number) * Multiplier;
   end To_Bytes;

   -------------------------
   -- Preliminary_Locale --
   -------------------------

   function Preliminary_Locale (Source : Arguments'Class) return String is
      Index : Positive := 1;
   begin
      while Index <= Source.Count loop
         declare
            Argument : constant String := Source.Value (Index);
         begin
            exit when Argument = "--";

            if Argument = "--locale" and then Index < Source.Count then
               return Source.Value (Index + 1);
            elsif T.Starts_With (Argument, "--locale=") then
               return Argument (Argument'First + 9 .. Argument'Last);
            end if;
         end;
         Index := Index + 1;
      end loop;

      return "";
   end Preliminary_Locale;

   ------------------------
   -- Preliminary_Color --
   ------------------------

   function Preliminary_Color
     (Source : Arguments'Class;
      Found  : out Boolean) return Color_Mode
   is
      Index : Positive := 1;

      function Decode (Text : String; Ok : out Boolean) return Color_Mode is
      begin
         for Mode in Color_Mode loop
            if Color_Name (Mode) = Text then
               Ok := True;
               return Mode;
            end if;
         end loop;
         Ok := False;
         return Color_Auto;
      end Decode;

   begin
      Found := False;

      while Index <= Source.Count loop
         declare
            Argument : constant String := Source.Value (Index);
            Ok       : Boolean;
         begin
            exit when Argument = "--";

            if T.Starts_With (Argument, "--color=") then
               declare
                  Mode : constant Color_Mode :=
                    Decode (Argument (Argument'First + 8 .. Argument'Last), Ok);
               begin
                  if Ok then
                     Found := True;
                     return Mode;
                  end if;
               end;
            elsif Argument = "--color" and then Index < Source.Count then
               declare
                  Mode : constant Color_Mode :=
                    Decode (Source.Value (Index + 1), Ok);
               begin
                  if Ok then
                     Found := True;
                     return Mode;
                  end if;
               end;
            end if;
         end;
         Index := Index + 1;
      end loop;

      return Color_Auto;
   end Preliminary_Color;

   -----------
   -- Parse --
   -----------

   procedure Parse
     (Source : Arguments'Class;
      Result : in out Command;
      Status : out E.Error_Info)
   is
      Index         : Positive := 1;
      Options_Ended : Boolean := False;
      Operands      : Natural := 0;

      --  Every option seen, in order, so that each can be judged against the
      --  command once there is one. An option may be typed before the
      --  command word, so this cannot be decided where it is read.
      Max_Seen_Options : constant := 64;
      Typed      : array (1 .. Max_Seen_Options) of Entry_Text :=
        [others => null];
      Typed_Used : Natural := 0;

      --  Track which options were seen so that a repeat is a usage error
      --  rather than a silent last-wins.
      type Option_Flag is
        (Flag_Prompt, Flag_Prompt_File, Flag_System, Flag_System_File,
         Flag_Max_Tokens, Flag_Context, Flag_Batch, Flag_Temperature,
         Flag_Top_K, Flag_Top_P, Flag_Min_P, Flag_Repeat_Penalty,
         Flag_Repeat_Window, Flag_Frequency_Penalty, Flag_Presence_Penalty,
         Flag_Chat_Template,
         Flag_Seed, Flag_Memory, Flag_Locale,
         Flag_Color, Flag_Mapping, Flag_Stats, Flag_Verbosity,
         Flag_Threads, Flag_Backend);
      Seen : array (Option_Flag) of Boolean := [others => False];

      procedure Fail (Code : E.Error_Code; Name : String; Detail : String := "")
      is
      begin
         Status := E.Make (Code);
         if Name /= "" then
            E.Add_Text (Status, "option", Name, E.Param_Identifier);
         end if;
         if Detail /= "" then
            E.Add_Text (Status, "value", Detail);
         end if;
      end Fail;

      --  Mark an option as seen, rejecting a repeat.
      procedure Mark (Flag : Option_Flag; Name : String; Ok : out Boolean) is
      begin
         if Seen (Flag) then
            Fail (E.CLI_Repeated_Option, Name);
            Ok := False;
         else
            Seen (Flag) := True;
            Ok := True;
         end if;
      end Mark;

      --  Refuse a value on an option that does not take one.
      --
      --  "--verbose=5" is a mistake, not a request: the value was dropped and
      --  the reader left believing it had been applied. The diagnostic for it
      --  has existed from the start with nothing producing it.
      procedure No_Value
        (Name          : String;
         Value_Present : Boolean;
         Value         : String;
         Ok            : out Boolean) is
      begin
         Ok := not Value_Present;
         if not Ok then
            Fail (E.CLI_Unexpected_Option_Value, Name, Value);
         end if;
      end No_Value;

      --  Read the value of an option, whether it was given as --name=value or
      --  as two arguments.
      procedure Take_Value
        (Name          : String;
         Value_Present : Boolean;
         Value_First   : Natural;
         Argument      : String;
         Target        : out Text_Access;
         Ok            : out Boolean) is
      begin
         Target := null;
         Ok := False;

         if Value_Present then
            Target := new String'(Argument (Value_First .. Argument'Last));
            Ok := True;
         elsif Index < Source.Count then
            Index := Index + 1;
            Target := new String'(Source.Value (Index));
            Ok := True;
         else
            Fail (E.CLI_Missing_Option_Value, Name);
         end if;
      end Take_Value;

   begin
      Release (Result);
      Result := (others => <>);
      Status := E.Success;

      while Index <= Source.Count loop
         declare
            Argument      : constant String := Source.Value (Index);
            Name_Last     : Natural;
            Value_First   : Natural;
            Value_Present : Boolean;
            Held          : Text_Access := null;
         begin
            if not Options_Ended and then Argument = "--" then
               Options_Ended := True;

            elsif not Options_Ended
              and then Argument'Length >= 2
              and then Argument (Argument'First .. Argument'First + 1) = "--"
            then
               Split (Argument, Name_Last, Value_First, Value_Present);

               declare
                  Name : constant String := Argument (Argument'First .. Name_Last);

                  --  Read a value and store it in a bounded field.
                  procedure Bounded_Value
                    (Flag   : Option_Flag;
                     Target : out T.Bounded;
                     Good   : out Boolean) is
                  begin
                     Target := T.Empty;
                     Mark (Flag, Name, Good);
                     if not Good then
                        return;
                     end if;
                     Take_Value (Name, Value_Present, Value_First, Argument,
                                 Held, Good);
                     if Good then
                        Target := T.To_Bounded (Held.all);
                        Free_Text (Held);
                     end if;
                  end Bounded_Value;

                  --  Read a value and store it as a natural number in range.
                  procedure Natural_Value
                    (Flag    : Option_Flag;
                     Minimum : Long_Long_Integer;
                     Maximum : Long_Long_Integer;
                     Target  : out Natural;
                     Good    : out Boolean)
                  is
                     Number : Long_Long_Integer;
                     Parsed : Boolean;
                  begin
                     Target := 0;
                     Mark (Flag, Name, Good);
                     if not Good then
                        return;
                     end if;
                     Take_Value (Name, Value_Present, Value_First, Argument,
                                 Held, Good);
                     if not Good then
                        return;
                     end if;

                     To_Number (Held.all, Number, Parsed);
                     if not Parsed then
                        Fail (E.CLI_Invalid_Option_Value, Name, Held.all);
                        Free_Text (Held);
                        Good := False;
                        return;
                     end if;
                     if Number < Minimum or else Number > Maximum then
                        Fail (E.CLI_Option_Out_Of_Range, Name, Held.all);
                        E.Add_Integer (Status, "minimum", Minimum);
                        E.Add_Integer (Status, "maximum", Maximum);
                        Free_Text (Held);
                        Good := False;
                        return;
                     end if;

                     Target := Natural (Number);
                     Free_Text (Held);
                  end Natural_Value;

                  --  Read a value and store it as a real number.
                  procedure Real_Value
                    (Flag   : Option_Flag;
                     Target : out Model_Runner.Numerics.Real;
                     Good   : out Boolean)
                  is
                     Parsed : Boolean;
                  begin
                     Target := 0.0;
                     Mark (Flag, Name, Good);
                     if not Good then
                        return;
                     end if;
                     Take_Value (Name, Value_Present, Value_First, Argument,
                                 Held, Good);
                     if not Good then
                        return;
                     end if;

                     To_Real (Held.all, Target, Parsed);
                     if not Parsed then
                        Fail (E.CLI_Invalid_Option_Value, Name, Held.all);
                        Free_Text (Held);
                        Good := False;
                        return;
                     end if;
                     Free_Text (Held);
                  end Real_Value;

                  Good : Boolean;
               begin
                  if Typed_Used < Max_Seen_Options then
                     Typed_Used := Typed_Used + 1;
                     Typed (Typed_Used) := Text (Name);
                  end if;

                  if Name = "--help" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     Result.Kind := Command_Help;

                  elsif Name = "--version" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     Result.Kind := Command_Version;

                  elsif Name = "--prompt" then
                     Mark (Flag_Prompt, Name, Good);
                     if not Good then
                        return;
                     end if;
                     Take_Value (Name, Value_Present, Value_First, Argument,
                                 Result.Prompt_Text, Good);
                     if not Good then
                        return;
                     end if;
                     if Result.Prompt_Kind /= Prompt_Unset then
                        Fail (E.CLI_Conflicting_Prompt_Sources, Name);
                        return;
                     end if;
                     Result.Prompt_Kind := Prompt_Inline;

                  elsif Name = "--prompt-file" then
                     Bounded_Value (Flag_Prompt_File, Result.Prompt_Path, Good);
                     if not Good then
                        return;
                     end if;
                     if Result.Prompt_Kind /= Prompt_Unset then
                        Fail (E.CLI_Conflicting_Prompt_Sources, Name);
                        return;
                     end if;
                     Result.Prompt_Kind := Prompt_File;

                  elsif Name = "--interactive" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     if Result.Prompt_Kind not in Prompt_Unset | Prompt_Interactive
                     then
                        Fail (E.CLI_Conflicting_Prompt_Sources, Name);
                        return;
                     end if;
                     Result.Prompt_Kind := Prompt_Interactive;

                  elsif Name = "--raw" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     Result.Raw := True;

                  elsif Name = "--system" then
                     Mark (Flag_System, Name, Good);
                     if not Good then
                        return;
                     end if;
                     Take_Value (Name, Value_Present, Value_First, Argument,
                                 Result.System_Text, Good);
                     if not Good then
                        return;
                     end if;
                     if Result.Has_System then
                        Fail (E.CLI_Conflicting_System_Sources, Name);
                        return;
                     end if;
                     Result.Has_System := True;

                  elsif Name = "--system-file" then
                     Bounded_Value (Flag_System_File, Result.System_Path, Good);
                     if not Good then
                        return;
                     end if;
                     if Result.Has_System then
                        Fail (E.CLI_Conflicting_System_Sources, Name);
                        return;
                     end if;
                     Result.Has_System := True;

                  elsif Name = "--max-tokens" then
                     Natural_Value (Flag_Max_Tokens, 1, 1_000_000,
                                    Result.Max_Tokens, Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--context-size" then
                     Natural_Value (Flag_Context, 1, 1_048_576,
                                    Result.Context_Size, Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--backend" then
                     declare
                        Chosen : Model_Runner.Text.Bounded;
                        Found  : Boolean := False;
                     begin
                        Bounded_Value (Flag_Backend, Chosen, Good);
                        if not Good then
                           return;
                        end if;

                        --  Matched against the backends this build has,
                        --  rather than a list written here that would go
                        --  stale the first time one was added.
                        for Kind in Model_Runner.Backend.Backend_Kind loop
                           if Model_Runner.Backend.Backend_Name (Kind)
                             = Model_Runner.Text.To_String (Chosen)
                           then
                              Result.Backend := Kind;
                              Found := True;
                           end if;
                        end loop;

                        if not Found then
                           Status := E.Make (E.Backend_Unknown);
                           E.Add_Text
                             (Status, "value",
                              Model_Runner.Text.To_String (Chosen),
                              E.Param_Identifier);
                           Good := False;
                           return;
                        end if;
                     end;

                  elsif Name = "--threads" then
                     Natural_Value (Flag_Threads, 0, 64, Result.Threads, Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--batch-size" then
                     Natural_Value (Flag_Batch, 1, 4096,
                                    Result.Batch_Size, Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--temperature" then
                     Real_Value (Flag_Temperature, Result.Sampling.Temperature,
                                 Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--top-k" then
                     Natural_Value (Flag_Top_K, 0, 1_000_000,
                                    Result.Sampling.Top_K, Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--top-p" then
                     Real_Value (Flag_Top_P, Result.Sampling.Top_P, Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--min-p" then
                     Real_Value (Flag_Min_P, Result.Sampling.Min_P, Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--chat-template" then
                     Bounded_Value
                       (Flag_Chat_Template, Result.Chat_Template, Good);
                     if not Good then
                        return;
                     end if;

                     --  Matched against the formats this build carries,
                     --  and refused by name when it has none -- the same
                     --  answer --backend gives, for the same question. It
                     --  said "invalid value for --chat-template" before,
                     --  which is true of any bad value and tells a reader
                     --  nothing about what this build has.
                     declare
                        Asked : constant String :=
                          Model_Runner.Text.To_String (Result.Chat_Template);
                        Found : Boolean := False;
                     begin
                        for Format in Model_Runner.Templates.Chat_Format loop
                           if Model_Runner.Templates.Format_Name (Format)
                             = Asked
                           then
                              Found := True;
                           end if;
                        end loop;

                        if not Found then
                           Status := E.Make (E.Template_Unknown_Format);
                           E.Add_Text
                             (Status, "value", Asked, E.Param_Identifier);
                           Good := False;
                           return;
                        end if;
                     end;

                  elsif Name = "--repeat-penalty" then
                     Real_Value (Flag_Repeat_Penalty,
                                 Result.Sampling.Repeat_Penalty, Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--frequency-penalty" then
                     Real_Value (Flag_Frequency_Penalty,
                                 Result.Sampling.Frequency_Penalty, Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--presence-penalty" then
                     Real_Value (Flag_Presence_Penalty,
                                 Result.Sampling.Presence_Penalty, Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--repeat-window" then
                     Natural_Value (Flag_Repeat_Window, 0, 1_000_000,
                                    Result.Sampling.Repeat_Window, Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--seed" then
                     declare
                        Number : Interfaces.Unsigned_64;
                        Parsed : Boolean;
                     begin
                        Mark (Flag_Seed, Name, Good);
                        if not Good then
                           return;
                        end if;
                        Take_Value (Name, Value_Present, Value_First, Argument,
                                    Held, Good);
                        if not Good then
                           return;
                        end if;
                        To_Unsigned (Held.all, Number, Parsed);
                        if not Parsed then
                           Fail (E.CLI_Invalid_Option_Value, Name, Held.all);
                           Free_Text (Held);
                           return;
                        end if;
                        Result.Seed := Number;
                        Result.Has_Seed := True;
                        Free_Text (Held);
                     end;

                  elsif Name = "--stop" then
                     Take_Value (Name, Value_Present, Value_First, Argument,
                                 Held, Good);
                     if not Good then
                        return;
                     end if;
                     if Result.Stop_Count >= Result.Stop_Strings'Length then
                        Fail (E.CLI_Option_Out_Of_Range, Name);
                        Free_Text (Held);
                        return;
                     end if;
                     Result.Stop_Count := Result.Stop_Count + 1;
                     Result.Stop_Strings (Result.Stop_Count) :=
                       T.To_Bounded (Held.all);
                     Free_Text (Held);

                  elsif Name = "--stop-token" then
                     declare
                        Number : Long_Long_Integer;
                        Parsed : Boolean;
                     begin
                        Take_Value (Name, Value_Present, Value_First, Argument,
                                    Held, Good);
                        if not Good then
                           return;
                        end if;
                        To_Number (Held.all, Number, Parsed);
                        if not Parsed or else Number < 0 then
                           Fail (E.CLI_Invalid_Option_Value, Name, Held.all);
                           Free_Text (Held);
                           return;
                        end if;
                        if Result.Stop_Token_Count >= Result.Stop_Tokens'Length
                        then
                           Fail (E.CLI_Option_Out_Of_Range, Name);
                           Free_Text (Held);
                           return;
                        end if;
                        Result.Stop_Token_Count := Result.Stop_Token_Count + 1;
                        Result.Stop_Tokens (Result.Stop_Token_Count) := Number;
                        Free_Text (Held);
                     end;

                  elsif Name = "--memory-limit" then
                     declare
                        Parsed : Boolean;
                     begin
                        Mark (Flag_Memory, Name, Good);
                        if not Good then
                           return;
                        end if;
                        Take_Value (Name, Value_Present, Value_First, Argument,
                                    Held, Good);
                        if not Good then
                           return;
                        end if;
                        To_Bytes (Held.all, Result.Memory_Limit, Parsed);
                        if not Parsed then
                           Fail (E.CLI_Invalid_Option_Value, Name, Held.all);
                           Free_Text (Held);
                           return;
                        end if;
                        Free_Text (Held);
                     end;

                  elsif Name = "--mmap" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     Mark (Flag_Mapping, Name, Good);
                     if not Good then
                        return;
                     end if;
                     Result.Mapping := Files.Mapping_Required;

                  elsif Name = "--no-mmap" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     Mark (Flag_Mapping, Name, Good);
                     if not Good then
                        return;
                     end if;
                     Result.Mapping := Files.Mapping_Disabled;

                  elsif Name = "--quiet" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     Mark (Flag_Verbosity, Name, Good);
                     if not Good then
                        return;
                     end if;
                     Result.Level := Quiet;

                  elsif Name = "--verbose" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     Mark (Flag_Verbosity, Name, Good);
                     if not Good then
                        return;
                     end if;
                     Result.Level := Verbose;

                  elsif Name = "--show-stats" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     Mark (Flag_Stats, Name, Good);
                     if not Good then
                        return;
                     end if;
                     Result.Show_Stats := True;
                     Result.Stats_Set := True;

                  elsif Name = "--no-stats" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     Mark (Flag_Stats, Name, Good);
                     if not Good then
                        return;
                     end if;
                     Result.Show_Stats := False;
                     Result.Stats_Set := True;

                  elsif Name = "--locale" then
                     Bounded_Value (Flag_Locale, Result.Locale, Good);
                     if not Good then
                        return;
                     end if;

                  elsif Name = "--color" then
                     Mark (Flag_Color, Name, Good);
                     if not Good then
                        return;
                     end if;
                     Take_Value (Name, Value_Present, Value_First, Argument,
                                 Held, Good);
                     if not Good then
                        return;
                     end if;
                     --  Matched against the modes this build has. The list
                     --  the message offers comes from the same place, so a
                     --  mode added is offered and one removed is not.
                     declare
                        Found : Boolean := False;
                     begin
                        for Mode in Color_Mode loop
                           if Color_Name (Mode) = Held.all then
                              Result.Color := Mode;
                              Found := True;
                           end if;
                        end loop;

                        if not Found then
                           Fail (E.CLI_Invalid_Color_Mode, Name, Held.all);
                           E.Add_Text
                             (Status, "expected", Color_Names,
                              E.Param_Identifier);
                           Free_Text (Held);
                           return;
                        end if;
                     end;
                     Free_Text (Held);

                  elsif Name = "--metadata" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     Result.Show_Metadata := True;

                  elsif Name = "--tensors" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     Result.Show_Tensors := True;

                  elsif Name = "--validate" then
                     No_Value (Name, Value_Present,
                               Argument (Value_First .. Argument'Last), Good);
                     if not Good then
                        return;
                     end if;
                     Result.Validate_Only := True;

                  else
                     Fail (E.CLI_Unknown_Option, Name);
                     return;
                  end if;
               end;

            else
               --  Operands: the command name, then the model path or the help
               --  topic.
               Operands := Operands + 1;

               if Operands = 1 and then Result.Kind = Command_None then
                  if Argument = "run" then
                     Result.Kind := Command_Run;
                  elsif Argument = "inspect" then
                     Result.Kind := Command_Inspect;
                  elsif Argument = "help" then
                     Result.Kind := Command_Help;
                  elsif Argument = "version" then
                     Result.Kind := Command_Version;
                  else
                     Fail (E.CLI_Unknown_Command, "", Argument);
                     return;
                  end if;

               elsif Operands = 2 then
                  case Result.Kind is
                     when Command_Run | Command_Inspect =>
                        Result.Model_Path := T.To_Bounded (Argument);
                     when Command_Help =>
                        Result.Help_Topic := T.To_Bounded (Argument);
                     when others =>
                        Fail (E.CLI_Unexpected_Operand, "", Argument);
                        return;
                  end case;

               else
                  Fail (E.CLI_Unexpected_Operand, "", Argument);
                  return;
               end if;
            end if;
         end;

         Index := Index + 1;
      end loop;

      if Result.Kind = Command_None then
         Status := E.Make (E.CLI_Missing_Command);
         return;
      end if;

      --  An option this command does not take is a usage error, not a
      --  setting to ignore. Every option used to reach every command:
      --  `inspect m.gguf --temperature 0.5 --interactive` ran the inspection
      --  and said nothing, so on a command documenting five options and
      --  accepting thirty-seven a typo and a setting looked alike.
      for Index in 1 .. Typed_Used loop
         if not Accepts (Result.Kind, Typed (Index).all) then
            Status := E.Make (E.CLI_Option_Not_For_Command);
            E.Add_Text
              (Status, "option", Typed (Index).all, E.Param_Identifier);
            E.Add_Text
              (Status, "value", Command_Word (Result.Kind),
               E.Param_Identifier);
            return;
         end if;
      end loop;

      if Result.Kind in Command_Run | Command_Inspect
        and then T.Is_Empty (Result.Model_Path)
      then
         Status := E.Make (E.CLI_Missing_Model_Path);
         return;
      end if;

      --  Raw mode has no conversation, so a system message has nowhere to go.
      --  Accepting it silently would change what the model sees without
      --  saying so.
      if Result.Raw and then Result.Has_System then
         Status := E.Make (E.CLI_Raw_Mode_Conflict);
         E.Add_Text (Status, "option", "--system", E.Param_Identifier);
         return;
      end if;

      Model_Runner.Sampling.Validate (Result.Sampling, Status);
   end Parse;

end Model_Runner.CLI.Options;
