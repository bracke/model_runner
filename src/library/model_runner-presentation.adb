with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.IO_Exceptions;
with Ada.Text_IO;
with Ada.Text_IO.Text_Streams;

with Terminal_Styles;

with Model_Runner.Backend;
with Model_Runner.Clocks;
with Model_Runner.Text;
with Model_Runner.UTF8;

package body Model_Runner.Presentation is

   use type Model_Runner.CLI.Options.Color_Mode;
   use type Model_Runner.CLI.Options.Verbosity;

   package E renames Model_Runner.Errors;
   use type E.Severity_Level;
   package Gen renames Model_Runner.Generation;
   package Loc renames Model_Runner.Localization;
   package Opt renames Model_Runner.CLI.Options;
   package T renames Model_Runner.Text;

   --  The agent-trace glyphs as their UTF-8 bytes, so this source stays plain
   --  ASCII: an arrow in for a call, an arrow out for a result, a check, a
   --  warning sign and a cross for the three kinds of ending.
   Glyph_Call   : constant String :=
     Character'Val (16#E2#) & Character'Val (16#86#) & Character'Val (16#92#);
   Glyph_Result : constant String :=
     Character'Val (16#E2#) & Character'Val (16#86#) & Character'Val (16#90#);
   Glyph_Ok     : constant String :=
     Character'Val (16#E2#) & Character'Val (16#9C#) & Character'Val (16#93#);
   Glyph_Warn   : constant String :=
     Character'Val (16#E2#) & Character'Val (16#9A#) & Character'Val (16#A0#);
   Glyph_Fail   : constant String :=
     Character'Val (16#E2#) & Character'Val (16#9C#) & Character'Val (16#97#);

   ----------
   -- Open --
   ----------

   procedure Open
     (Item         : in out Console;
      Catalog      : access constant Loc.Catalog;
      Mode         : Opt.Color_Mode;
      Capabilities : Terminal_Capabilities;
      Level        : Opt.Verbosity) is
   begin
      Item.Catalog := Catalog;
      Item.Mode := Mode;
      Item.Capabilities := Capabilities;
      Item.Level := Level;

      --  Terminal_Styles keeps a colour policy of its own, and its own
      --  policy defaults to auto and judges auto by whether standard output
      --  is a terminal. That gated everything a second time, after this
      --  console had already decided: --color always wrote no colour at all
      --  whenever the destination was not a terminal, which is the only
      --  arrangement in which always differs from auto. Three modes
      --  collapsed to two and the one a caller reaches for when piping to a
      --  pager was the one that did nothing.
      --
      --  A global judged by one stream cannot answer a question asked per
      --  stream, and this console knows the mode, the destination and
      --  whether NO_COLOR was set. So the library is told to emit what it is
      --  asked for and the decision stays here, in Styles, where all three
      --  of those are in hand.
      Terminal_Styles.Set_Color_Policy (Terminal_Styles.Color_Always);
   end Open;

   --  Report whether a destination may carry escape sequences.
   function Styled (Item : Console; Is_Terminal : Boolean) return Boolean is
   begin
      case Item.Mode is
         when Opt.Color_Never  => return False;
         when Opt.Color_Always => return True;
         when Opt.Color_Auto   =>
            return Is_Terminal and then not Item.Capabilities.Colour_Suppressed;
      end case;
   end Styled;

   -------------------------
   -- Styles_Diagnostics --
   -------------------------

   function Styles_Diagnostics (Item : Console) return Boolean
   is (Styled (Item, Item.Capabilities.Error_Is_Terminal));

   --  Whether the stream a line is going to is a terminal.
   --
   --  Every styling decision used to ask this of standard error, whatever
   --  stream the line was going to. That was invisible while only the error
   --  stream carried anything worth colouring; the moment the inspection
   --  report moved to standard output, `inspect MODEL > report.txt` began
   --  writing escape sequences into the file whenever a terminal was still
   --  attached to standard error, which is the ordinary case. A destination
   --  now names its own state, and the answer follows the line.
   function Attached (Item : Console; Where : Destination) return Boolean
   is (case Where is
         when Answer     => Item.Capabilities.Output_Is_Terminal,
         when Diagnostic => Item.Capabilities.Error_Is_Terminal);

   --  Whether a line going to this stream may carry escape sequences.
   --
   --  This is the whole decision. It used to be half of one: what it
   --  answered was then handed to Terminal_Styles along with the stream's
   --  terminal state, which gated the styling a second time -- so
   --  --color always produced nothing whenever the destination was not a
   --  terminal, which is the only arrangement in which it differs from
   --  auto. Three modes collapsed to two, and the mode a caller reaches for
   --  when piping to a pager was the one that did nothing.
   function Styles (Item : Console; Where : Destination) return Boolean
   is (Styled (Item, Attached (Item, Where)));

   --  Look up a localized message, tolerating an absent catalog.
   function Message
     (Item      : Console;
      Key       : String;
      Arguments : Loc.Argument_List := Loc.Empty_Arguments) return String is
   begin
      if Item.Catalog = null then
         return "<" & Key & ">";
      else
         return Loc.Text (Item.Catalog.all, Key, Arguments);
      end if;
   end Message;

   --------------------
   -- Message_Value --
   --------------------

   function Message_Value (Item : Console; Key : String) return String
   is (Message (Item, Key));

   --  Finish any partially drawn progress line before something else is
   --  written to the same stream.

   --------------
   -- Put_Line --
   --------------

   --  Current_Output rather than Standard_Output. The program never
   --  redirects it, so this is the same file it always was; a test can, and
   --  until it could, nothing read the help screen. Three option lines lost
   --  their indentation and their place in the list and survived three
   --  commits and a full checklist run, because every check read the catalog
   --  the lines come from and none read the screen they land on.
   --
   --  Generated text does not come through here. It goes to standard output
   --  as raw bytes through a sink of its own, which is deliberate and stays
   --  that way.
   procedure Put_Line (Item : in out Console; Text : String) is
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Current_Output, Text);
   exception
      when Ada.IO_Exceptions.Device_Error | Ada.IO_Exceptions.Use_Error =>
         null;
   end Put_Line;

   ------------------
   -- Put_Message --
   ------------------

   --------------------
   -- Use_Structured --
   --------------------

   procedure Use_Structured (Item : in out Console; On : Boolean) is
   begin
      Item.Structured := On;
   end Use_Structured;

   -------------------
   -- Is_Structured --
   -------------------

   function Is_Structured (Item : Console) return Boolean
   is (Item.Structured);

   --  A text as a JSON string.
   function Quoted (Text : String) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String;
      Hex    : constant String := "0123456789abcdef";
   begin
      Ada.Strings.Unbounded.Append (Result, '"');
      for C of Text loop
         case C is
            when '"'      => Ada.Strings.Unbounded.Append (Result, "\""");
            when '\'     => Ada.Strings.Unbounded.Append (Result, "\\");
            when ASCII.LF => Ada.Strings.Unbounded.Append (Result, "\n");
            when ASCII.CR => Ada.Strings.Unbounded.Append (Result, "\r");
            when ASCII.HT => Ada.Strings.Unbounded.Append (Result, "\t");
            when ASCII.NUL .. ASCII.BS | ASCII.VT | ASCII.FF | ASCII.SO .. ASCII.US =>
               Ada.Strings.Unbounded.Append
                 (Result, "\u00" & Hex (Character'Pos (C) / 16 + 1)
                          & Hex (Character'Pos (C) mod 16 + 1));
            when others   => Ada.Strings.Unbounded.Append (Result, C);
         end case;
      end loop;
      Ada.Strings.Unbounded.Append (Result, '"');
      return Ada.Strings.Unbounded.To_String (Result);
   end Quoted;

   --  One record for a program: what kind it is, its key, its values and
   --  its text.
   procedure Put_Record
     (Item      : in out Console;
      Kind      : String;
      Key       : String;
      Arguments : Loc.Argument_List;
      Text      : String)
   is
      Line : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String
          ("{""kind"": " & Quoted (Kind) & ", ""key"": " & Quoted (Key));
   begin
      for One of Arguments loop
         Ada.Strings.Unbounded.Append
           (Line, ", " & Quoted (Model_Runner.Text.To_String (One.Name)) & ": "
                  & Quoted (Model_Runner.Text.To_String (One.Value)));
      end loop;
      Ada.Strings.Unbounded.Append (Line, ", ""text"": " & Quoted (Text) & "}");
      Put_Line (Item, Ada.Strings.Unbounded.To_String (Line));
   end Put_Record;

   procedure Put_Message
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List := Loc.Empty_Arguments) is
   begin
      if Item.Structured then
         Put_Record (Item, "message", Key, Arguments, Message (Item, Key, Arguments));
         return;
      end if;
      Put_Line (Item, Message (Item, Key, Arguments));
   end Put_Message;

   --  Write one line to standard error, tolerating a closed destination.
   --
   --  The console is passed and not read. It was read, to close a progress
   --  line left half-written, and that line never existed: the flag saying
   --  one was open was declared, initialized to False, tested, and set by
   --  nothing. The parameter stays because every writer here takes one and a
   --  writer that does not is a writer somebody will call from the wrong
   --  place.
   procedure Error_Line (Item : in out Console; Text : String) is
      pragma Unreferenced (Item);
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Current_Error, Text);
   exception
      when Ada.IO_Exceptions.Device_Error | Ada.IO_Exceptions.Use_Error =>
         null;
   end Error_Line;

   --  Write one line to the stream the caller named. The two writers it
   --  chooses between are the whole of the streams policy; everything that
   --  can go either way comes through here.
   procedure Write_Line
     (Item : in out Console; Where : Destination; Text : String) is
   begin
      case Where is
         when Answer =>
            Put_Line (Item, Text);
         when Diagnostic =>
            Error_Line (Item, Text);
      end case;
   end Write_Line;

   ------------------
   -- Put_Heading --
   ------------------

   procedure Put_Heading
     (Item  : in out Console;
      Key   : String;
      Where : Destination)
   is
      Label : constant String := Message (Item, Key);
   begin
      Write_Line
        (Item, Where,
         (if Styles (Item, Where)
          then Terminal_Styles.Decorate (Label, Terminal_Styles.Role_Header)
          else Label));
   end Put_Heading;

   ----------------
   -- Put_Field --
   ----------------

   procedure Put_Field
     (Item  : in out Console;
      Key   : String;
      Value : String;
      Where : Destination)
   is
      Label : constant String := Message (Item, Key);

      --  Padding is counted in code points, not bytes: a label with a
      --  non-ASCII character would otherwise be padded short and the column
      --  would break in every locale but English.
      Width : constant Natural := Model_Runner.UTF8.Code_Point_Count (Label);
      Shown : constant Natural := (if Width = 0 then Label'Length else Width);
      Padding : constant Natural := (if Shown >= 24 then 1 else 24 - Shown);
   begin
      Write_Line
        (Item, Where,
         "  "
         & (if Styles (Item, Where)
            then Terminal_Styles.Decorate (Label, Terminal_Styles.Role_Muted)
            else Label)
         & String'(1 .. Padding => ' ')
         & Value);
   end Put_Field;

   ---------------------
   -- Put_Data_Field --
   ---------------------

   procedure Put_Data_Field
     (Item  : in out Console;
      Label : String;
      Value : String;
      Where : Destination)
   is
      --  Padded like Put_Field, in code points rather than bytes, so a key
      --  with a non-ASCII character does not break the column.
      Width : constant Natural := Model_Runner.UTF8.Code_Point_Count (Label);
      Shown : constant Natural := (if Width = 0 then Label'Length else Width);
      Padding : constant Natural := (if Shown >= 40 then 1 else 40 - Shown);
   begin
      Write_Line
        (Item, Where,
         "  "
         & (if Styles (Item, Where)
            then Terminal_Styles.Decorate (Label, Terminal_Styles.Role_Muted)
            else Label)
         & String'(1 .. Padding => ' ')
         & Value);
   end Put_Data_Field;

   ----------------
   -- Put_Note --
   ----------------

   --  A next step as a session types it: each command it names as its
   --  slash command.
   function As_Typed_In_Session (Text : String) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String;

      --  Whether a command's words start at a place in the text.
      function Names_A_Command (At_Index : Positive) return Boolean is
         function Here (Phrase : String) return Boolean
         is (At_Index + Phrase'Length - 1 <= Text'Last
             and then Text (At_Index .. At_Index + Phrase'Length - 1) = Phrase);
      begin
         return Here ("task accept") or else Here ("task complete") or else Here ("task integrate")
           or else Here ("task new") or else Here ("task move") or else Here ("task verify")
           or else Here ("task list") or else Here ("req accept") or else Here ("req new")
           or else Here ("req reject") or else Here ("req obsolete") or else Here ("req lists")
           or else Here ("bootstrap FILE") or else Here ("reconfigure ")
           or else Here ("check consistency") or else Here ("work TASK-") or else Here ("result RES-")
           or else Here ("task cancel") or else Here ("task reject") or else Here ("task depend")
           or else Here ("task show") or else Here ("task audit") or else Here ("req show")
           or else Here ("req unlink") or else Here ("req supersede") or else Here ("req revise")
           or else Here ("decision revise") or else Here ("decision reject")
           or else Here ("spec revise") or else Here ("check REQ-") or else Here ("check full")
           or else Here ("config shows");
      end Names_A_Command;
   begin
      for Index in Text'Range loop
         if (Index = Text'First or else Text (Index - 1) in ' ' | '(')
           and then Names_A_Command (Index)
         then
            Ada.Strings.Unbounded.Append (Result, "/");
         end if;
         Ada.Strings.Unbounded.Append (Result, Text (Index));
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end As_Typed_In_Session;

   procedure Put_Note
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List := Loc.Empty_Arguments)
   is
      Said : constant String :=
        (if Item.Session then As_Typed_In_Session (Message (Item, Key, Arguments))
         else Message (Item, Key, Arguments));
   begin
      if Item.Structured then
         Put_Record (Item, "note", Key, Arguments, Said);
         return;
      end if;
      if Item.Level = Opt.Quiet then
         return;
      end if;
      Error_Line
        (Item,
         Message
           (Item, "diagnostic.note",
            [Loc.Named ("detail", Said)]));
   end Put_Note;

   ---------------
   -- Put_Aside --
   ---------------

   procedure Put_Aside
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List := Loc.Empty_Arguments) is
   begin
      if Item.Structured then
         Put_Record (Item, "note", Key, Arguments, Message (Item, Key, Arguments));
         return;
      end if;
      Error_Line (Item, Message (Item, Key, Arguments));
   end Put_Aside;

   -----------------
   -- Use_Session --
   -----------------

   procedure Use_Session (Item : in out Console; On : Boolean) is
   begin
      Item.Session := On;
   end Use_Session;

   -------------------
   -- Put_Tool_Call --
   -------------------

   procedure Put_Tool_Call
     (Item : in out Console; Named : String; Arguments : String)
   is
      Styled : constant Boolean := Styles_Diagnostics (Item);
   begin
      if Item.Level = Opt.Quiet then
         return;
      end if;
      Error_Line
        (Item,
         (if Styled then Glyph_Call & " " else "-> ")
         & (if Styled
            then Terminal_Styles.Decorate (Named, Terminal_Styles.Role_Header)
            else Named)
         & " "
         & (if Styled
            then Terminal_Styles.Decorate
                   (Arguments, Terminal_Styles.Role_Muted)
            else Arguments));
   end Put_Tool_Call;

   ---------------------
   -- Put_Tool_Result --
   ---------------------

   procedure Put_Tool_Result (Item : in out Console; Result : String) is
      Styled : constant Boolean := Styles_Diagnostics (Item);
   begin
      if Item.Level = Opt.Quiet then
         return;
      end if;
      Error_Line
        (Item,
         (if Styled then Glyph_Result & " " else "<- ")
         & (if Styled
            then Terminal_Styles.Decorate (Result, Terminal_Styles.Role_Muted)
            else Result));
   end Put_Tool_Result;

   -----------------------
   -- Put_Agent_Outcome --
   -----------------------

   procedure Put_Agent_Outcome
     (Item   : in out Console;
      State  : String;
      Steps  : Natural;
      Calls  : Natural;
      Result : Agent_Result)
   is
      Styled : constant Boolean := Styles_Diagnostics (Item);
      Role   : constant Terminal_Styles.Style_Role :=
        (case Result is
           when Answered_Well => Terminal_Styles.Role_Success,
           when Stopped_Short => Terminal_Styles.Role_Warning,
           when Failed        => Terminal_Styles.Role_Error);
      Glyph  : constant String :=
        (if Styled
         then (case Result is
                 when Answered_Well => Glyph_Ok,
                 when Stopped_Short => Glyph_Warn,
                 when Failed        => Glyph_Fail)
         else (case Result is
                 when Answered_Well => "ok",
                 when Stopped_Short => "!",
                 when Failed        => "x"));
   begin
      if Item.Level = Opt.Quiet then
         return;
      end if;
      Error_Line
        (Item,
         Glyph & " "
         & Message
             (Item, "cli.agent.stopped",
              [Loc.Named ("state",
                          (if Styled
                           then Terminal_Styles.Decorate (State, Role)
                           else State)),
               Loc.Named ("count", T.Image (Long_Long_Integer (Steps))),
               Loc.Named ("total", T.Image (Long_Long_Integer (Calls)))]));
   end Put_Agent_Outcome;

   ------------------
   -- Put_Prompt --
   ------------------

   procedure Put_Prompt (Item : in out Console; Key : String) is
   begin
      Ada.Text_IO.Put (Ada.Text_IO.Current_Error, Message (Item, Key) & ' ');
      Ada.Text_IO.Flush (Ada.Text_IO.Current_Error);
   exception
      when others =>
         null;
   end Put_Prompt;

   ------------------
   -- Put_Option --
   ------------------

   procedure Put_Option
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List := Loc.Empty_Arguments) is
   begin
      Put_Line (Item, "  " & Message (Item, Key, Arguments));
   end Put_Option;

   ------------
   -- Report --
   ------------

   procedure Report
     (Item      : in out Console;
      Condition : E.Error_Info)
   is
      Role : constant Terminal_Styles.Style_Role :=
        (case Condition.Severity is
            when E.Severity_Information => Terminal_Styles.Role_Info,
            when E.Severity_Warning     => Terminal_Styles.Role_Warning,
            when others                 => Terminal_Styles.Role_Error);

      Severity : constant String :=
        (if Item.Catalog = null
         then "error"
         else Loc.Severity_Label (Item.Catalog.all, Condition.Severity));

      Detail : constant String :=
        (if Item.Catalog = null
         then E.Message_Key (Condition.Code)
         else Loc.Describe (Item.Catalog.all, Condition));
   begin
      if E.Is_Ok (Condition) then
         return;
      end if;
      if Condition.Severity = E.Severity_Error then
         Item.Error_Count := Item.Error_Count + 1;
         if Item.Failure = 0 then
            Item.Failure := E.Exit_Status (Condition);
         end if;
      end if;

      if Item.Structured then
         --  Each of the condition's named values a field of its own -- a
         --  missing input's name, a path, an offset -- so that a program
         --  reads what went wrong without reading the text.
         declare
            use type Loc.Argument_List;

            function Value_Of (One : E.Parameter) return String
            is (case One.Kind is
                   when E.Param_Integer | E.Param_Bytes | E.Param_Tokens | E.Param_Offset =>
                      T.Image (One.Int_Value),
                   when E.Param_Boolean => (if One.Bool_Value then "true" else "false"),
                   when E.Param_Real => Long_Float'Image (One.Real_Value),
                   when others => T.To_String (One.Text_Value));

            function With_Parameters (From : Positive) return Loc.Argument_List
            is (if From > Condition.Parameter_Total then Loc.Argument_List'(1 .. 0 => <>)
                else Loc.Named (T.To_String (Condition.Parameters (From).Name),
                                Value_Of (Condition.Parameters (From)))
                     & With_Parameters (From + 1));
         begin
            Put_Record
              (Item, "error", E.Diagnostic_Code (Condition.Code),
               Loc.Named ("severity", Severity) & With_Parameters (1), Detail);
         end;
         return;
      end if;

      --  The label is coloured after the line is rendered: a rendered
      --  argument has its control characters escaped, which would print the
      --  colour's escape sequence as text.
      declare
         Line : constant String :=
           Message
             (Item, "diagnostic.line",
              [Loc.Named ("severity", Severity),
               Loc.Named ("code", E.Diagnostic_Code (Condition.Code)),
               Loc.Named ("detail", Detail)]);
         At_Label : constant Natural :=
           (if Severity'Length = 0 then 0
            else Ada.Strings.Fixed.Index (Line, Severity));
      begin
         if Styles_Diagnostics (Item) and then At_Label > 0 then
            Error_Line
              (Item,
               Line (Line'First .. At_Label - 1)
               & Terminal_Styles.Decorate (Severity, Role)
               & Line (At_Label + Severity'Length .. Line'Last));
         else
            Error_Line (Item, Line);
         end if;
      end;

      --  Technical context is verbose-only, and never carries prompt text,
      --  system messages or generated output.
      if Item.Level = Opt.Verbose then
         if Condition.Has_Location then
            Error_Line
              (Item,
               Message
                 (Item, "diagnostic.offset",
                  [Loc.Named
                     ("offset",
                      T.Image (Long_Long_Integer (Condition.Location)))]));
         end if;

         for Index in 1 .. Condition.Frame_Total loop
            Error_Line
              (Item,
               Message
                 (Item, "diagnostic.frame",
                  [Loc.Named
                     ("detail", T.To_String (Condition.Frames (Index)))]));
         end loop;
      end if;

      --  What can be done about it, from the class the code already carries.
      --  A cancelled run and a closed pipe get nothing, which is the honest
      --  answer: neither is a mistake anybody made.
      if Condition.Severity = E.Severity_Error then
         declare
            Hint : constant String :=
              E.Recovery_Hint (Condition.Code);
         begin
            if Hint /= "" then
               Put_Note (Item, Hint);
            end if;
         end;
      end if;
   end Report;

   -------------------
   -- First_Failure --
   -------------------

   function First_Failure (Item : in out Console; Reset : Boolean := True) return Natural is
      Result : constant Natural := Item.Failure;
   begin
      if Reset then
         Item.Failure := 0;
      end if;
      return Result;
   end First_Failure;

   ---------------------
   -- Errors_Reported --
   ---------------------

   function Errors_Reported (Item : Console) return Natural is (Item.Error_Count);

   ----------
   -- Warn --
   ----------

   procedure Warn
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List := Loc.Empty_Arguments)
   is
      Severity : constant String :=
        (if Item.Catalog = null
         then "warning"
         else Loc.Severity_Label (Item.Catalog.all, E.Severity_Warning));
   begin
      if Item.Level = Opt.Quiet then
         return;
      end if;

      Error_Line
        (Item,
         Message
           (Item, "diagnostic.warning_line",
            [Loc.Named
               ("severity",
                (if Styles_Diagnostics (Item)
                 then Terminal_Styles.Decorate
                        (Severity, Terminal_Styles.Role_Warning)
                 else Severity)),
             Loc.Named ("detail", Message (Item, Key, Arguments))]));
   end Warn;

   ----------------------
   -- Put_Statistics --
   ----------------------

   procedure Put_Statistics
     (Item           : in out Console;
      Outcome        : Gen.Result;
      Device         : String := "";
      Resident       : Natural := 0;
      Resident_Limit : Natural := 0;
      Imported       : Natural := 0;
      Resident_Bytes : Interfaces.Unsigned_64 := 0;
      Given_Back     : Natural := 0;
      Cached_Bytes   : Interfaces.Unsigned_64 := 0;
      State_Bytes    : Interfaces.Unsigned_64 := 0;
      Layers_Whole   : Natural := 0;
      Layers_Handed  : Natural := 0;
      Layers_Split   : Natural := 0;
      Handed_Why     : String := "";
      Blocks_Moved   : Natural := 0;
      Rings_Moved    : Natural := 0)
   is
      function Seconds (Value : Model_Runner.Clocks.Nanoseconds) return String
      is (Message
            (Item, "statistics.seconds",
             [Loc.Named
                ("value",
                 T.Image
                   (Long_Float (Value)
                    / Long_Float (Model_Runner.Clocks.Nanoseconds_Per_Second),
                    3))]));

      function Rate (Value : Long_Float) return String
      is (Message
            (Item, "statistics.per_second",
             [Loc.Named ("value", T.Image (Value, 2))]));
   begin
      Put_Heading (Item, "statistics.heading", Diagnostic);
      Put_Field
        (Item, "statistics.prompt_tokens",
         T.Image (Long_Long_Integer (Outcome.Prompt_Tokens)), Diagnostic);
      Put_Field
        (Item, "statistics.generated_tokens",
         T.Image (Long_Long_Integer (Outcome.Generated_Tokens)), Diagnostic);
      Put_Field
        (Item, "statistics.context_position",
         T.Image (Long_Long_Integer (Outcome.Final_Position)), Diagnostic);
      Put_Field
        (Item, "statistics.seed", T.Image (Outcome.Seed), Diagnostic);
      Put_Field (Item, "statistics.prefill_duration", Seconds (Outcome.Prefill_Ns), Diagnostic);
      Put_Field (Item, "statistics.decode_duration", Seconds (Outcome.Decode_Ns), Diagnostic);
      Put_Field (Item, "statistics.prefill_rate", Rate (Outcome.Prefill_Rate), Diagnostic);
      Put_Field (Item, "statistics.decode_rate", Rate (Outcome.Decode_Rate), Diagnostic);
      Put_Field
        (Item, "statistics.backend",
         Model_Runner.Backend.Backend_Name (Outcome.Backend), Diagnostic);
      Put_Field
        (Item, "statistics.workers",
         T.Image (Long_Long_Integer (Outcome.Workers)), Diagnostic);
      Put_Field
        (Item, "statistics.weights",
         Message
           (Item,
            (if Outcome.Weights_Mapped
             then "statistics.weights.mapped"
             else "statistics.weights.read")), Diagnostic);
      --  What a draft model proposed and how much of it was taken, for a
      --  run that had one. The only number that says whether the draft was
      --  worth its own passes.
      if Outcome.Shifted > 0 then
         Put_Field
           (Item, "statistics.shifted",
            T.Image (Long_Long_Integer (Outcome.Shifted)), Diagnostic);
      end if;

      if Outcome.Drafted > 0 then
         Put_Field
           (Item, "statistics.drafted",
            T.Image (Long_Long_Integer (Outcome.Drafted)), Diagnostic);
         Put_Field
           (Item, "statistics.accepted",
            T.Image (Long_Long_Integer (Outcome.Accepted)), Diagnostic);
      end if;

      --  What the device did with the model, for a run that used one. A
      --  count of matrices given back is the one number here that says a
      --  run was slower than it looked: everything above zero was uploaded
      --  again, and a device being fed the same weights is a device that is
      --  not helping.
      if Device /= "" then
         Put_Field (Item, "statistics.device", Device, Diagnostic);
         --  The count beside the bound it is held under.
         --
         --  It printed the count alone, and the count sat at exactly 4,096
         --  on a mixture of experts while three and a half gigabytes of the
         --  budget went unspent, and nothing said that the number next to
         --  the label WAS the bound. A reader who sees "4096 of 4096" asks
         --  the question; a reader who sees "4096" does not.
         Put_Field
           (Item, "statistics.resident",
            T.Image (Long_Long_Integer (Resident)) & " of "
            & T.Image (Long_Long_Integer (Resident_Limit)), Diagnostic);
         Put_Field
           (Item, "statistics.imported",
            T.Image (Long_Long_Integer (Imported)), Diagnostic);
         Put_Field
           (Item, "statistics.resident_bytes",
            T.Image (Long_Long_Integer (Resident_Bytes)), Diagnostic);
         Put_Field
           (Item, "statistics.given_back",
            T.Image (Long_Long_Integer (Given_Back)), Diagnostic);

         --  And whether the context is there as well as the weights. A
         --  device holding one and not the other attends on the processor,
         --  and nothing here used to say so.
         Put_Field
           (Item, "statistics.cached_bytes",
            T.Image (Long_Long_Integer (Cached_Bytes)), Diagnostic);

         --  And the rings, for a hybrid: said only where there are any,
         --  since every other architecture would read a nought there and
         --  wonder what it was.
         if Interfaces.">" (State_Bytes, 0) then
            Put_Field
              (Item, "statistics.state_bytes",
               T.Image (Long_Long_Integer (State_Bytes)), Diagnostic);
         end if;

         --  And how much of the model went over as one sequence. A layer
         --  refused goes over in pieces instead, or on the processor,
         --  and the lines above say nothing about it: a session whose
         --  keys are packed four bits wide had every layer refused --
         --  its rows are narrower than the word the packing writes --
         --  while the report showed a device holding the weights and
         --  the context, as it does when the whole model runs there.
         --  The reason is the first refused layer's, which is every one
         --  of them in practice: the shapes of a model's layers do not
         --  differ from token to token.
         if Layers_Whole + Layers_Handed + Layers_Split > 0 then
            Put_Field
              (Item, "statistics.layers_whole",
               T.Image (Long_Long_Integer (Layers_Whole)) & " of "
               & T.Image
                   (Long_Long_Integer
                      (Layers_Whole + Layers_Handed + Layers_Split)),
               Diagnostic);

            if Layers_Split > 0 then
               Put_Field
                 (Item, "statistics.layers_split",
                  T.Image (Long_Long_Integer (Layers_Split)), Diagnostic);
            end if;

            if Layers_Handed > 0 and then Handed_Why /= "" then
               Put_Field
                 (Item, "statistics.layers_handed",
                  Message (Item, Handed_Why), Diagnostic);
            end if;
         end if;

         if Blocks_Moved > 0 then
            Put_Field
              (Item, "statistics.blocks_moved",
               T.Image (Long_Long_Integer (Blocks_Moved)), Diagnostic);
         end if;

         if Rings_Moved > 0 then
            Put_Field
              (Item, "statistics.rings_moved",
               T.Image (Long_Long_Integer (Rings_Moved)), Diagnostic);
         end if;
      end if;

      Put_Field
        (Item, "statistics.completion_reason",
         Message (Item, "completion." & Gen.Reason_Name (Outcome.Reason)), Diagnostic);
   end Put_Statistics;

   -------------
   -- Explain --
   -------------

   overriding procedure Explain
     (Item   : in out Logprob_Reporter;
      Report : Model_Runner.Sampling.Explanation)
   is
      --  A number a reader and a program can both take. Six digits, which is
      --  more than the arithmetic behind it carries and enough that two
      --  tokens of nearly equal probability do not print the same.
      function Shown (Value : Model_Runner.Sampling.Real) return String
      is (T.Image (Long_Float (Value), 6));

      Line : String (1 .. 1024) := [others => ' '];
      Used : Natural := 0;

      procedure Put (Text : String) is
         Room : constant Natural :=
           Natural'Min (Text'Length, Line'Length - Used);
      begin
         Line (Used + 1 .. Used + Room) :=
           Text (Text'First .. Text'First + Room - 1);
         Used := Used + Room;
      end Put;
   begin
      Put ("token ");
      Put (T.Image (Long_Long_Integer (Report.Chosen)));
      Put (" logprob ");
      Put (Shown (Report.Log_Of));

      for Index in 1 .. Report.Count loop
         Put (" | ");
         Put (T.Image (Long_Long_Integer (Report.Tokens (Index))));
         Put (" ");
         Put (Shown (Report.Log_Values (Index)));
      end loop;

      Write_Line (Item.Screen.all, Diagnostic, Line (1 .. Used));
   end Explain;

   -----------
   -- Write --
   -----------

   overriding procedure Write
     (Self   : in out Standard_Output_Sink;
      Item   : String;
      Closed : out Boolean) is
   begin
      if Self.Closed then
         Closed := True;
         return;
      end if;

      --  Written through the raw stream rather than Ada.Text_IO. Text_IO
      --  tracks a column and appends a line terminator when a partially
      --  written line is closed, which would append a newline the model never
      --  produced. Generated text is passed through byte for byte.
      --
      --  Standard_Output rather than Current_Output, which is where this
      --  briefly went. A test that wants this text redirects the file
      --  descriptor instead -- there is a capture in the suite that does --
      --  and sending it through Current_Output puts it in the middle of
      --  whatever else a test was capturing there, which is how a layout
      --  check came to read " a Statistics" as a line.
      String'Write
        (Ada.Text_IO.Text_Streams.Stream (Ada.Text_IO.Standard_Output), Item);
      Closed := False;
   exception
      --  A broken pipe is an ordinary end, not a failure to report with a
      --  traceback.
      when others =>
         Self.Closed := True;
         Closed := True;
   end Write;

   -----------
   -- Flush --
   -----------

   overriding procedure Flush
     (Self : in out Standard_Output_Sink; Closed : out Boolean) is
   begin
      if Self.Closed then
         Closed := True;
         return;
      end if;

      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Output);
      Closed := False;
   exception
      when others =>
         Self.Closed := True;
         Closed := True;
   end Flush;

   ---------------
   -- Is_Closed --
   ---------------

   overriding function Is_Closed (Self : Standard_Output_Sink) return Boolean
   is (Self.Closed);

   ------------
   -- Notify --
   ------------

   overriding procedure Notify
     (Self : in out Progress_Reporter;
      Item : Model_Runner.Progress.Event)
   is
      package P renames Model_Runner.Progress;
      Owner : Console renames Self.Owner.all;
   begin
      if Owner.Level = Opt.Quiet then
         return;
      end if;

      --  Progress is noise on a redirected stream unless it was asked for.
      if not Owner.Capabilities.Error_Is_Terminal
        and then Owner.Level /= Opt.Verbose
      then
         return;
      end if;

      declare
         Key : constant String :=
           (case Item.Kind is
               when P.Load_Event =>
                  "progress.loading."
                  & T.To_Lower (P.Load_Stage'Image (Item.Load)),
               when P.Generation_Event =>
                  "progress.generation."
                  & T.To_Lower (P.Generation_Stage'Image (Item.Generation)));
         Line : constant String :=
           Message
             (Owner, Key,
              [Loc.Named ("completed", T.Image (Long_Long_Integer (Item.Completed))),
               Loc.Named ("total", T.Image (Long_Long_Integer (Item.Total)))]);
      begin
         Ada.Text_IO.Put_Line (Ada.Text_IO.Current_Error, Line);
      end;
   exception
      --  An observer must never fail the work it is observing.
      when others =>
         null;
   end Notify;

end Model_Runner.Presentation;
