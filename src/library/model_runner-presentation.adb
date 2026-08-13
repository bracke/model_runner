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
   --  Generated text does not come through here. It goes out as raw bytes
   --  through a sink of its own, which is deliberate and stays that way --
   --  and that sink writes to Current_Output's stream for the same reason
   --  this does.
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

   procedure Put_Message
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List := Loc.Empty_Arguments) is
   begin
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

   procedure Put_Note
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List := Loc.Empty_Arguments) is
   begin
      if Item.Level = Opt.Quiet then
         return;
      end if;
      Error_Line
        (Item,
         Message
           (Item, "diagnostic.note",
            [Loc.Named ("detail", Message (Item, Key, Arguments))]));
   end Put_Note;

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

      Error_Line
        (Item,
         Message
           (Item, "diagnostic.line",
            [Loc.Named
               ("severity",
                (if Styles_Diagnostics (Item)
                 then Terminal_Styles.Decorate (Severity, Role)
                 else Severity)),
             Loc.Named ("code", E.Diagnostic_Code (Condition.Code)),
             Loc.Named ("detail", Detail)]));

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
      Imported       : Natural := 0;
      Resident_Bytes : Interfaces.Unsigned_64 := 0;
      Given_Back     : Natural := 0)
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
      --  What a draft model proposed and how much of it was taken, for a
      --  run that had one. The only number that says whether the draft was
      --  worth its own passes.
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
         Put_Field
           (Item, "statistics.resident",
            T.Image (Long_Long_Integer (Resident)), Diagnostic);
         Put_Field
           (Item, "statistics.imported",
            T.Image (Long_Long_Integer (Imported)), Diagnostic);
         Put_Field
           (Item, "statistics.resident_bytes",
            T.Image (Long_Long_Integer (Resident_Bytes)), Diagnostic);
         Put_Field
           (Item, "statistics.given_back",
            T.Image (Long_Long_Integer (Given_Back)), Diagnostic);
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
      --  Through Current_Output's stream, which is the same file as
      --  Standard_Output for this program -- it never redirects it -- and is
      --  not the same file for a test, which can. It was Standard_Output,
      --  and while it was, nothing could read what the program generated
      --  without running it as a process: the one comparison worth making
      --  between this command and the tool that publishes figures for it is
      --  whether they produce the same text, and it could not be made.
      --  Raw either way; only the file differs.
      String'Write
        (Ada.Text_IO.Text_Streams.Stream (Ada.Text_IO.Current_Output), Item);
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
