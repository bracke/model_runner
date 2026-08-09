with Ada.IO_Exceptions;
with Ada.Text_IO;
with Ada.Text_IO.Text_Streams;

with Terminal_Styles;

with Model_Runner.Clocks;
with Model_Runner.Text;
with Model_Runner.UTF8;

package body Model_Runner.Presentation is

   use type Model_Runner.CLI.Options.Color_Mode;
   use type Model_Runner.CLI.Options.Verbosity;

   package E renames Model_Runner.Errors;
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
      Item.Progress_Open := False;
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
   procedure Close_Progress (Item : in out Console) is
   begin
      if Item.Progress_Open then
         Ada.Text_IO.New_Line (Ada.Text_IO.Current_Error);
         Item.Progress_Open := False;
      end if;
   end Close_Progress;

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
      Close_Progress (Item);
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
   procedure Error_Line (Item : in out Console; Text : String) is
   begin
      Close_Progress (Item);
      Ada.Text_IO.Put_Line (Ada.Text_IO.Current_Error, Text);
   exception
      when Ada.IO_Exceptions.Device_Error | Ada.IO_Exceptions.Use_Error =>
         null;
   end Error_Line;

   ------------------
   -- Put_Heading --
   ------------------

   procedure Put_Heading (Item : in out Console; Key : String) is
      Label : constant String := Message (Item, Key);
   begin
      Error_Line
        (Item,
         (if Styles_Diagnostics (Item)
          then Terminal_Styles.Decorate
                 (Label, Terminal_Styles.Role_Header,
                  Item.Capabilities.Error_Is_Terminal)
          else Label));
   end Put_Heading;

   ----------------
   -- Put_Field --
   ----------------

   procedure Put_Field
     (Item  : in out Console;
      Key   : String;
      Value : String)
   is
      Label : constant String := Message (Item, Key);

      --  Padding is counted in code points, not bytes: a label with a
      --  non-ASCII character would otherwise be padded short and the column
      --  would break in every locale but English.
      Width : constant Natural := Model_Runner.UTF8.Code_Point_Count (Label);
      Shown : constant Natural := (if Width = 0 then Label'Length else Width);
      Padding : constant Natural := (if Shown >= 24 then 1 else 24 - Shown);
   begin
      Error_Line
        (Item,
         "  "
         & (if Styles_Diagnostics (Item)
            then Terminal_Styles.Decorate
                   (Label, Terminal_Styles.Role_Muted,
                    Item.Capabilities.Error_Is_Terminal)
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
      Value : String)
   is
      --  Padded like Put_Field, in code points rather than bytes, so a key
      --  with a non-ASCII character does not break the column.
      Width : constant Natural := Model_Runner.UTF8.Code_Point_Count (Label);
      Shown : constant Natural := (if Width = 0 then Label'Length else Width);
      Padding : constant Natural := (if Shown >= 40 then 1 else 40 - Shown);
   begin
      Error_Line
        (Item,
         "  "
         & (if Styles_Diagnostics (Item)
            then Terminal_Styles.Decorate
                   (Label, Terminal_Styles.Role_Muted,
                    Item.Capabilities.Error_Is_Terminal)
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
      Close_Progress (Item);
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
                 then Terminal_Styles.Decorate
                        (Severity, Role, Item.Capabilities.Error_Is_Terminal)
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
                        (Severity, Terminal_Styles.Role_Warning,
                         Item.Capabilities.Error_Is_Terminal)
                 else Severity)),
             Loc.Named ("detail", Message (Item, Key, Arguments))]));
   end Warn;

   ----------------------
   -- Put_Statistics --
   ----------------------

   procedure Put_Statistics
     (Item    : in out Console;
      Outcome : Gen.Result)
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
      Put_Heading (Item, "statistics.heading");
      Put_Field
        (Item, "statistics.prompt_tokens",
         T.Image (Long_Long_Integer (Outcome.Prompt_Tokens)));
      Put_Field
        (Item, "statistics.generated_tokens",
         T.Image (Long_Long_Integer (Outcome.Generated_Tokens)));
      Put_Field
        (Item, "statistics.context_position",
         T.Image (Long_Long_Integer (Outcome.Final_Position)));
      Put_Field
        (Item, "statistics.seed", T.Image (Outcome.Seed));
      Put_Field (Item, "statistics.prefill_duration", Seconds (Outcome.Prefill_Ns));
      Put_Field (Item, "statistics.decode_duration", Seconds (Outcome.Decode_Ns));
      Put_Field (Item, "statistics.prefill_rate", Rate (Outcome.Prefill_Rate));
      Put_Field (Item, "statistics.decode_rate", Rate (Outcome.Decode_Rate));
      Put_Field
        (Item, "statistics.completion_reason",
         Message (Item, "completion." & Gen.Reason_Name (Outcome.Reason)));
   end Put_Statistics;

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
         Close_Progress (Owner);
         Ada.Text_IO.Put_Line (Ada.Text_IO.Current_Error, Line);
      end;
   exception
      --  An observer must never fail the work it is observing.
      when others =>
         null;
   end Notify;

end Model_Runner.Presentation;
