with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.IO_Exceptions;
with Ada.Text_IO.Text_Streams;

with Terminal_Styles;

with Model_Runner.Backend;
with Model_Runner.Clocks;
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

   function Styles_Answers (Item : Console) return Boolean
   is (Styles (Item, Answer) and then not Item.Structured);

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
                  & Quoted (Ada.Strings.Unbounded.To_String (One.Value)));
      end loop;
      Ada.Strings.Unbounded.Append (Line, ", ""text"": " & Quoted (Text) & "}");
      Put_Line (Item, Ada.Strings.Unbounded.To_String (Line));
   end Put_Record;

   --  A text with the commands it names coloured, as a terminal shows
   --  them: /task accept TASK-001 -- the command and its actions in one
   --  colour, what they are given -- an identifier, a placeholder, a
   --  setting, a path -- in another, the words around them left as they
   --  are. Only the session's own commands: a path is not one.
   function Commands_Coloured (Text : String) return String is
      Commands : constant String :=
        " init bootstrap state config reconfigure task accept reject work cancel check req decision spec"
        & " result scan tree sym refs deps users impact trace git sandbox instruct help exit reset settings"
        & " stats context system tools tool save load image video projects ";
      Actions  : constant String :=
        " list new show accept reject reconsider obsolete verify revise link unlink supersede govern move"
        & " block unblock cancel complete reopen edit note grant withhold depend split rehome plan diff"
        & " integrate kept restore drop add remove dismiss dismissed derive audit context all withdraw"
        & " consistency full anyway resolved discard none project ";

      function Lower_Word (Word : String) return Boolean
      is (Word /= "" and then (for all C of Word => C in 'a' .. 'z' | '_'));

      --  Something a command is given: not a plain word of the sentence.
      function Given_Word (Word : String) return Boolean is
         Bare : constant String :=
           (if Word'Length > 1 and then Word (Word'Last) in ',' | ';' | ':' | '.' | ')'
            then Word (Word'First .. Word'Last - 1) else Word);
      begin
         return Bare /= ""
           and then not Lower_Word (Bare)
           --  Another command, or a value left to the reader, is no argument.
           and then Bare (Bare'First) /= '/'
           and then Ada.Strings.Fixed.Index (Bare, "...") = 0
           and then (for all C of Bare => C not in '(' | '"')
           and then (for some C of Bare =>
                       C in 'A' .. 'Z' | '0' .. '9' | '=' | '.' | '/' | '-' | '_' | '|' | '[' | ']');
      end Given_Word;

      Result : Ada.Strings.Unbounded.Unbounded_String;
      At_Char : Natural := Text'First;
   begin
      if Ada.Strings.Fixed.Index (Text, "/") = 0 or else Ada.Strings.Fixed.Index (Text, [1 => ASCII.ESC]) > 0 then
         return Text;
      end if;
      while At_Char <= Text'Last loop
         if Text (At_Char) = '/'
           and then (At_Char = Text'First or else Text (At_Char - 1) in ' ' | '(' | '`' | '"' | ASCII.HT)
           and then At_Char < Text'Last and then Text (At_Char + 1) in 'a' .. 'z'
         then
            declare
               Stop : Natural := At_Char + 1;
            begin
               while Stop < Text'Last and then Text (Stop + 1) in 'a' .. 'z' | '_' loop
                  Stop := Stop + 1;
               end loop;
               if Ada.Strings.Fixed.Index (Commands, " " & Text (At_Char + 1 .. Stop) & " ") > 0
                 and then (Stop = Text'Last or else Text (Stop + 1) not in '/' | '.' | '-')
               then
                  --  The command, then its actions, then what it is given.
                  declare
                     Head_End : Natural := Stop;
                     Args_End : Natural := Stop;
                     Cursor   : Natural := Stop + 1;
                     In_Args  : Boolean := False;
                  begin
                     while Cursor <= Text'Last and then Text (Cursor) = ' ' loop
                        declare
                           Word_End : Natural := Cursor;
                        begin
                           while Word_End < Text'Last and then Text (Word_End + 1) /= ' ' loop
                              Word_End := Word_End + 1;
                           end loop;
                           declare
                              Word : constant String := Text (Cursor + 1 .. Word_End);
                              Bare : constant String :=
                                (if Word'Length > 1 and then Word (Word'Last) in ',' | ';' | ':' | ')'
                                 then Word (Word'First .. Word'Last - 1) else Word);
                           begin
                              exit when Word = "";
                              if not In_Args and then Ada.Strings.Fixed.Index (Actions, " " & Bare & " ") > 0 then
                                 Head_End := Cursor + Bare'Length;
                                 Args_End := Head_End;
                                 --  What follows new or note is words, not arguments.
                                 exit when Bare in "new" | "note";
                              elsif Given_Word (Word) then
                                 In_Args := True;
                                 Args_End := Cursor + Bare'Length;
                              else
                                 exit;
                              end if;
                              exit when Bare'Length < Word'Length;
                              Cursor := Word_End + 1;
                           end;
                        end;
                     end loop;
                     Ada.Strings.Unbounded.Append
                       (Result, Terminal_Styles.Decorate (Text (At_Char .. Head_End), Terminal_Styles.Role_Info));
                     if Args_End > Head_End then
                        Ada.Strings.Unbounded.Append
                          (Result, Terminal_Styles.Decorate (Text (Head_End + 1 .. Args_End),
                                                             Terminal_Styles.Role_Header));
                     end if;
                     At_Char := Args_End + 1;
                  end;
               else
                  Ada.Strings.Unbounded.Append (Result, Text (At_Char .. Stop));
                  At_Char := Stop + 1;
               end if;
            end;
         else
            Ada.Strings.Unbounded.Append (Result, Text (At_Char));
            At_Char := At_Char + 1;
         end if;
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end Commands_Coloured;

   procedure Put_Message
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List := Loc.Empty_Arguments) is
   begin
      if Item.Structured then
         Put_Record (Item, "message", Key, Arguments, Message (Item, Key, Arguments));
         return;
      end if;
      Put_Line (Item, (if Styles (Item, Answer) then Commands_Coloured (Message (Item, Key, Arguments))
                       else Message (Item, Key, Arguments)));
   end Put_Message;

   ----------------
   -- Put_Header --
   ----------------

   procedure Put_Header
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List := Loc.Empty_Arguments) is
   begin
      if Item.Structured or else not Styles (Item, Answer) then
         Put_Message (Item, Key, Arguments);
      else
         Put_Line (Item, Terminal_Styles.Decorate (Message (Item, Key, Arguments), Terminal_Styles.Role_Header));
      end if;
   end Put_Header;

   ------------------
   -- Put_Indented --
   ------------------

   procedure Put_Indented
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List;
      Indent    : Positive := 2)
   is
      Lead : constant String (1 .. Indent) := [others => ' '];
   begin
      if Item.Structured then
         Put_Message (Item, Key, Arguments);
      else
         Put_Line (Item, Lead & Message (Item, Key, Arguments));
      end if;
   end Put_Indented;

   ----------------
   -- Size_Image --
   ----------------

   function Size_Image (Bytes : Interfaces.Unsigned_64) return String is
      use type Interfaces.Unsigned_64;
      Exact : constant String := T.Image (Long_Long_Integer (Bytes));
   begin
      if Bytes < 1024 then
         return Exact & " bytes";
      end if;
      declare
         Units  : constant array (1 .. 4) of String (1 .. 3) := ["KiB", "MiB", "GiB", "TiB"];
         Amount : Long_Float := Long_Float (Bytes);
         Unit   : Natural := 0;
      begin
         while Amount >= 1024.0 and then Unit < 4 loop
            Amount := Amount / 1024.0;
            Unit := Unit + 1;
         end loop;
         return T.Image (Amount, 1) & " " & Units (Unit) & " (" & Exact & " bytes)";
      end;
   end Size_Image;

   -----------------
   -- Put_Section --
   -----------------

   procedure Put_Section (Item : in out Console; Key : String) is
   begin
      if not Item.Structured then
         Put_Line (Item, "");
      end if;
      Put_Header (Item, Key);
   end Put_Section;

   -------------
   -- Tone_Of --
   -------------

   function Tone_Of (State : String) return Tone is
      Word : constant String := Ada.Characters.Handling.To_Lower (Ada.Strings.Fixed.Trim (State, Ada.Strings.Both));
   begin
      if Word in "complete" | "completed" | "verified" | "passed" | "pass" | "done" | "integrated" | "ready"
        | "ok" | "yes" | "true"
      then
         return Good;
      elsif Word in "failed" | "fail" | "blocked" | "deprecated" | "conflicted" | "error" | "blocking" then
         return Bad;
      --  Ended by choice: finished with, not gone wrong.
      elsif Word in "cancelled" | "rejected" | "superseded" | "obsolete" | "retired" | "withdrawn" then
         return Muted;
      elsif Word in "candidate" | "proposed" | "accepted" | "running" | "verification" | "implemented"
        | "waiting" | "open" | "pending" | "warning" | "stale" | "stopped"
      then
         return Pending;
      else
         return Plain;
      end if;
   end Tone_Of;

   --  The role a tone is coloured in.
   function Role_Of (Value_Tone : Tone) return Terminal_Styles.Style_Role
   is (case Value_Tone is
          when Plain | Good => Terminal_Styles.Role_Success,
          when Pending      => Terminal_Styles.Role_Warning,
          when Bad          => Terminal_Styles.Role_Error,
          when Muted        => Terminal_Styles.Role_Muted);

   ----------------
   -- Put_Marked --
   ----------------

   procedure Put_Marked
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List;
      Mark      : String;
      Mark_Tone : Tone)
   is
      function Letter (C : Character) return Boolean
      is (Ada.Characters.Handling.Is_Alphanumeric (C) or else C in '_' | '-');
   begin
      if Item.Structured or else not Styles (Item, Answer) or else Mark = "" or else Mark_Tone = Plain then
         Put_Message (Item, Key, Arguments);
         return;
      end if;
      declare
         Line : constant String := Message (Item, Key, Arguments);
         From    : Positive := Line'First;
         At_Mark : Natural := 0;
         Found   : Boolean := False;
      begin
         --  The word whole: "accepted" is not marked in "unaccepted".
         while From <= Line'Last loop
            At_Mark := Ada.Strings.Fixed.Index (Line (From .. Line'Last), Mark);
            exit when At_Mark = 0;
            if (At_Mark = Line'First or else not Letter (Line (At_Mark - 1)))
              and then (At_Mark + Mark'Length > Line'Last or else not Letter (Line (At_Mark + Mark'Length)))
            then
               Found := True;
               exit;
            end if;
            From := At_Mark + 1;
         end loop;
         if not Found then
            Put_Line (Item, Line);
         else
            Put_Line (Item, Line (Line'First .. At_Mark - 1)
                            & Terminal_Styles.Decorate (Mark, Role_Of (Mark_Tone))
                            & Line (At_Mark + Mark'Length .. Line'Last));
         end if;
      end;
   end Put_Marked;

   -------------------
   -- Put_Diff_Line --
   -------------------

   procedure Put_Diff_Line (Item : in out Console; Text : String) is
      function Starts (Prefix : String) return Boolean
      is (Text'Length >= Prefix'Length and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);
   begin
      if Item.Structured or else not Styles (Item, Answer) or else Text = "" then
         Put_Line (Item, Text);
      elsif Starts ("+++") or else Starts ("---") or else Starts ("@@") or else Starts ("diff ")
        or else Starts ("index ")
      then
         Put_Line (Item, Terminal_Styles.Decorate (Text, Terminal_Styles.Role_Muted));
      elsif Starts ("+") then
         Put_Line (Item, Terminal_Styles.Decorate (Text, Terminal_Styles.Role_Success));
      elsif Starts ("-") then
         Put_Line (Item, Terminal_Styles.Decorate (Text, Terminal_Styles.Role_Error));
      else
         Put_Line (Item, Text);
      end if;
   end Put_Diff_Line;

   --------------
   -- Put_Pair --
   --------------

   procedure Put_Pair
     (Item       : in out Console;
      Key        : String;
      Name       : String;
      Value      : String;
      Value_Tone : Tone := Plain;
      Indent     : Natural := 0)
   is
      Lead : constant String (1 .. Indent) := [others => ' '];
   begin
      if Item.Structured then
         Put_Message (Item, Key, [Loc.Named ("name", Name), Loc.Named ("value", Value)]);
         return;
      elsif not Styles (Item, Answer) then
         Put_Line (Item, Lead & Message (Item, Key, [Loc.Named ("name", Name), Loc.Named ("value", Value)]));
         return;
      end if;
      --  Coloured in the line as the catalog words it, not in what it is
      --  given: a value is escaped as data, and so would its colour be.
      declare
         Line    : constant String :=
           Message (Item, Key, [Loc.Named ("name", Name), Loc.Named ("value", Value)]);
         Trimmed : constant String := Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both);
         At_Name : constant Natural :=
           (if Trimmed = "" then 0 else Ada.Strings.Fixed.Index (Line, Trimmed));
         At_Value : constant Natural :=
           (if Value = "" then 0 else Ada.Strings.Fixed.Index (Line, Value, Ada.Strings.Backward));
         Role    : constant Terminal_Styles.Style_Role :=
           (case Value_Tone is
               when Plain | Good => Terminal_Styles.Role_Success,
               when Pending      => Terminal_Styles.Role_Warning,
               when Bad          => Terminal_Styles.Role_Error,
               when Muted        => Terminal_Styles.Role_Muted);
      begin
         --  Either not found as given -- the catalog changed it -- the line
         --  is said plain.
         if At_Name = 0 or else At_Value = 0 or else At_Value < At_Name + Trimmed'Length then
            Put_Line (Item, Lead & Line);
            return;
         end if;
         Put_Line
           (Item,
            Lead & Line (Line'First .. At_Name - 1)
            & Terminal_Styles.Decorate (Trimmed, Terminal_Styles.Role_Muted)
            & Line (At_Name + Trimmed'Length .. At_Value - 1)
            & (if Value_Tone = Plain then Commands_Coloured (Value) else Terminal_Styles.Decorate (Value, Role))
            & Line (At_Value + Value'Length .. Line'Last));
      end;
   end Put_Pair;

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
      Where : Destination;
      Gap   : Boolean := False)
   is
      Label : constant String := Message (Item, Key);
   begin
      if Gap and then not Item.Structured then
         Write_Line (Item, Where, "");
      end if;
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
     (Item       : in out Console;
      Key        : String;
      Value      : String;
      Where      : Destination;
      Value_Tone : Tone := Plain)
   is
      Label : constant String := Message (Item, Key);

      --  Padding is counted in code points, not bytes: a label with a
      --  non-ASCII character would otherwise be padded short and the column
      --  would break in every locale but English.
      Width : constant Natural := Model_Runner.UTF8.Code_Point_Count (Label);
      Shown : constant Natural := (if Width = 0 then Label'Length else Width);
      Padding : constant Natural := (if Shown >= 32 then 1 else 32 - Shown);
   begin
      Write_Line
        (Item, Where,
         "  "
         & (if Styles (Item, Where)
            then Terminal_Styles.Decorate (Label, Terminal_Styles.Role_Muted)
            else Label)
         & String'(1 .. Padding => ' ')
         & (if not Styles (Item, Where) then Value
            elsif Value_Tone = Plain then Commands_Coloured (Value)
            else Terminal_Styles.Decorate (Value, Role_Of (Value_Tone))));
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

   ----------------
   -- In_Session --
   ----------------

   function In_Session (Item : Console) return Boolean is (Item.Session);

   ---------------------
   -- Looks_Like_JSON --
   ---------------------

   function Looks_Like_JSON (Text : String) return Boolean is
      Bare : constant String := Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
   begin
      return Bare'Length >= 2
        and then ((Bare (Bare'First) = '{' and then Bare (Bare'Last) = '}')
                  or else (Bare (Bare'First) = '[' and then Bare (Bare'Last) = ']'));
   end Looks_Like_JSON;

   -------------------
   -- JSON_Coloured --
   -------------------

   function JSON_Coloured (Text : String) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String;
      Index  : Natural := Text'First;

      procedure Add (Part : String; Role : Terminal_Styles.Style_Role) is
      begin
         Ada.Strings.Unbounded.Append (Result, Terminal_Styles.Decorate (Part, Role));
      end Add;

      function Starts_Word (Word : String) return Boolean
      is (Index + Word'Length - 1 <= Text'Last and then Text (Index .. Index + Word'Length - 1) = Word);
   begin
      while Index <= Text'Last loop
         declare
            C : constant Character := Text (Index);
         begin
            if C = '"' then
               --  A string to its closing quote, escapes and all; a key where
               --  a colon follows it.
               declare
                  Stop  : Natural := Index + 1;
                  After : Natural;
               begin
                  while Stop <= Text'Last and then Text (Stop) /= '"' loop
                     if Text (Stop) = '\' then
                        Stop := Stop + 1;
                     end if;
                     Stop := Stop + 1;
                  end loop;
                  Stop := Natural'Min (Stop, Text'Last);
                  After := Stop + 1;
                  while After <= Text'Last and then Text (After) in ' ' | ASCII.HT loop
                     After := After + 1;
                  end loop;
                  Add (Text (Index .. Stop),
                       (if After <= Text'Last and then Text (After) = ':' then Terminal_Styles.Role_Info
                        else Terminal_Styles.Role_Success));
                  Index := Stop + 1;
               end;
            elsif C in '0' .. '9' or else (C = '-' and then Index < Text'Last and then Text (Index + 1) in '0' .. '9')
            then
               declare
                  Stop : Natural := Index + 1;
               begin
                  while Stop <= Text'Last and then Text (Stop) in '0' .. '9' | '.' | 'e' | 'E' | '+' | '-' loop
                     Stop := Stop + 1;
                  end loop;
                  Add (Text (Index .. Stop - 1), Terminal_Styles.Role_Warning);
                  Index := Stop;
               end;
            elsif Starts_Word ("true") or else Starts_Word ("null") then
               Add (Text (Index .. Index + 3), Terminal_Styles.Role_Warning);
               Index := Index + 4;
            elsif Starts_Word ("false") then
               Add (Text (Index .. Index + 4), Terminal_Styles.Role_Warning);
               Index := Index + 5;
            elsif C in '{' | '}' | '[' | ']' | ',' | ':' then
               Add ([1 => C], Terminal_Styles.Role_Muted);
               Index := Index + 1;
            else
               Ada.Strings.Unbounded.Append (Result, C);
               Index := Index + 1;
            end if;
         end;
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end JSON_Coloured;

   -------------
   -- Put_Row --
   -------------

   procedure Put_Row
     (Item       : in out Console;
      Main       : String;
      Aside      : String;
      Indent     : Natural := 0;
      Main_Tone  : Tone := Plain;
      Mute_Aside : Boolean := True)
   is
      Lead   : constant String (1 .. Indent) := [others => ' '];
      Styled : constant Boolean := Styles (Item, Answer) and then not Item.Structured;
   begin
      Put_Line (Item, Lead
                      & (if Styled and then Main_Tone /= Plain
                         then Terminal_Styles.Decorate (Main, Role_Of (Main_Tone)) else Main)
                      & (if Aside = "" then ""
                         elsif Styled and then Mute_Aside
                         then "  " & Terminal_Styles.Decorate (Aside, Terminal_Styles.Role_Muted)
                         else "  " & Aside));
   end Put_Row;

   -------------------
   -- Put_Help_Line --
   -------------------

   --  A line with the commands it names coloured where colour shows.
   function Command_Bold (Item : Console; Line : String) return String is
   begin
      --  The command it is about coloured as every command is.
      return (if Styles_Diagnostics (Item) then Commands_Coloured (Line) else Line);
   end Command_Bold;

   procedure Put_Help_Line (Item : in out Console; Key : String) is
   begin
      if Item.Structured then
         Put_Record (Item, "note", Key, Loc.Empty_Arguments, Message (Item, Key));
         return;
      end if;
      Error_Line (Item, Command_Bold (Item, Message (Item, Key)));
   end Put_Help_Line;

   ---------------
   -- Put_Usage --
   ---------------

   procedure Put_Usage (Item : in out Console; Key : String) is
      Text  : constant String := Message (Item, Key);
      Start : Positive := Text'First;
   begin
      if Item.Structured then
         Put_Record (Item, "note", Key, Loc.Empty_Arguments, Text);
         return;
      end if;
      loop
         declare
            Cut  : constant Natural := Ada.Strings.Fixed.Index (Text (Start .. Text'Last), " -- ");
            Part : constant String :=
              Ada.Strings.Fixed.Trim (Text (Start .. (if Cut = 0 then Text'Last else Cut - 1)), Ada.Strings.Both);
         begin
            if Part /= "" then
               Error_Line (Item, "  " & Command_Bold (Item, Part));
            end if;
            exit when Cut = 0;
            Start := Cut + 4;
         end;
      end loop;
   end Put_Usage;

   ----------------------
   -- Put_Aside_Marked --
   ----------------------

   procedure Put_Aside_Marked
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List;
      Mark      : String;
      Mark_Tone : Tone)
   is
      Line    : constant String := Message (Item, Key, Arguments);
      At_Mark : constant Natural := (if Mark = "" then 0 else Ada.Strings.Fixed.Index (Line, Mark));
   begin
      if Item.Structured then
         Put_Record (Item, "note", Key, Arguments, Line);
      elsif At_Mark = 0 or else Mark_Tone = Plain or else not Styles_Diagnostics (Item) then
         Error_Line (Item, Line);
      else
         Error_Line (Item, Line (Line'First .. At_Mark - 1)
                           & Terminal_Styles.Decorate (Mark, Role_Of (Mark_Tone))
                           & Line (At_Mark + Mark'Length .. Line'Last));
      end if;
   end Put_Aside_Marked;

   ---------------------
   -- Next_Step_Value --
   ---------------------

   function Next_Step_Value
     (Item      : Console;
      Key       : String;
      Arguments : Loc.Argument_List) return String
   is (Message (Item, Key, Arguments));

   procedure Hold_Next_Steps (Item : in out Console; Held : Boolean) is
   begin
      Item.Next_Held := Held;
   end Hold_Next_Steps;

   procedure Put_Note
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List := Loc.Empty_Arguments)
   is
      Said : constant String := Message (Item, Key, Arguments);
   begin
      if Item.Next_Held and then Key'Length > 9 and then Key (Key'First .. Key'First + 8) = "cli.next." then
         return;
      end if;
      if Item.Structured then
         Put_Record (Item, "note", Key, Arguments, Said);
         return;
      end if;
      if Item.Level = Opt.Quiet then
         return;
      end if;
      --  The way on set apart from what it says at a terminal that shows
      --  colour: its "next:" muted, coloured after the line is rendered.
      declare
         --  Coloured once rendered: an argument's escapes are escaped.
         Line    : constant String :=
           (if Styles_Diagnostics (Item)
            then Commands_Coloured (Message (Item, "diagnostic.note", [Loc.Named ("detail", Said)]))
            else Message (Item, "diagnostic.note", [Loc.Named ("detail", Said)]));
         Lead    : constant String := Message (Item, "diagnostic.next_lead");
         --  Its way on dimmed wherever the note begins with one.
         At_Lead : constant Natural :=
           (if Lead = "" or else Said'Length < Lead'Length
              or else Said (Said'First .. Said'First + Lead'Length - 1) /= Lead
            then 0 else Ada.Strings.Fixed.Index (Line, Lead));
      begin
         if Styles_Diagnostics (Item) and then At_Lead > 0 then
            Error_Line
              (Item,
               Line (Line'First .. At_Lead - 1)
               & Terminal_Styles.Decorate (Lead, Terminal_Styles.Role_Muted)
               & Line (At_Lead + Lead'Length .. Line'Last));
         else
            Error_Line (Item, Line);
         end if;
      end;
   end Put_Note;

   ---------------
   -- Put_Aside --
   ---------------

   procedure Put_Aside
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List := Loc.Empty_Arguments;
      Indent    : Natural := 0)
   is
      Lead : constant String (1 .. Indent) := [others => ' '];
   begin
      if Item.Structured then
         Put_Record (Item, "note", Key, Arguments, Message (Item, Key, Arguments));
         return;
      end if;
      Error_Line (Item, Lead & (if Styles_Diagnostics (Item) then Commands_Coloured (Message (Item, Key, Arguments))
                                else Message (Item, Key, Arguments)));
   end Put_Aside;

   -----------------
   -- Use_Session --
   -----------------

   procedure Use_Session (Item : in out Console; On : Boolean) is
   begin
      Item.Session := On;
   end Use_Session;

   -----------------
   -- Use_Command --
   -----------------

   procedure Use_Command (Item : in out Console; Word : String) is
   begin
      Item.Command := Model_Runner.Text.To_Bounded (Word);
   end Use_Command;

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
         --  Its arguments as JSON is read, where they are JSON.
         & (if Styled and then Looks_Like_JSON (Arguments) then JSON_Coloured (Arguments)
            elsif Styled
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
         --  A result that is JSON coloured as JSON; any other muted.
         & (if Styled and then Looks_Like_JSON (Result) then JSON_Coloured (Result)
            elsif Styled
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

   function Coloured_Commands (Item : Console; Text : String) return String
   is (if Styles_Diagnostics (Item) then Commands_Coloured (Text) else Text);

   procedure Clear_Screen (Item : in out Console) is
   begin
      if Item.Capabilities.Error_Is_Terminal then
         Ada.Text_IO.Put (Ada.Text_IO.Current_Error, ASCII.ESC & "[H" & ASCII.ESC & "[2J");
         Ada.Text_IO.Flush (Ada.Text_IO.Current_Error);
      end if;
   exception
      when others =>
         null;
   end Clear_Screen;

   procedure Put_After_Prompt
     (Item      : in out Console;
      Key       : String;
      Arguments : Loc.Argument_List) is
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Current_Error, Message (Item, Key, Arguments));
      Ada.Text_IO.Flush (Ada.Text_IO.Current_Error);
   exception
      when others =>
         null;
   end Put_After_Prompt;

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
            --  And its code muted: looked up, not read.
            declare
               Code    : constant String := E.Diagnostic_Code (Condition.Code);
               Rest    : constant String := Line (At_Label + Severity'Length .. Line'Last);
               At_Code : constant Natural := (if Code = "" then 0 else Ada.Strings.Fixed.Index (Rest, Code));
            begin
               Error_Line
                 (Item,
                  Line (Line'First .. At_Label - 1)
                  & Terminal_Styles.Decorate (Severity, Role)
                  --  The commands it names coloured, as anywhere.
                  & (if At_Code = 0 then Commands_Coloured (Rest)
                     else Rest (Rest'First .. At_Code - 1)
                          & Terminal_Styles.Decorate (Code, Terminal_Styles.Role_Muted)
                          & Commands_Coloured (Rest (At_Code + Code'Length .. Rest'Last))));
            end;
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
            if Hint = "diagnostic.hint.usage" and then Item.Session
              and then E."=" (Condition.Code, E.CLI_Unknown_Command)
            then
               --  The error says where the commands are listed already.
               null;
            elsif Hint = "diagnostic.hint.usage" and then Item.Session
              and then not Model_Runner.Text.Is_Empty (Item.Command)
            then
               Put_Note (Item, "diagnostic.hint.usage_command",
                         [Loc.Named ("name", Model_Runner.Text.To_String (Item.Command))]);
            elsif Hint = "diagnostic.hint.usage" and then Item.Session then
               Put_Note (Item, "diagnostic.hint.usage_session");
            elsif Hint = "diagnostic.hint.context"
              and then (for some Index in 1 .. Condition.Parameter_Total =>
                          T.To_String (Condition.Parameters (Index).Name)
                          = "total")
            then
               --  The size that holds the request, where the error says.
               for Index in 1 .. Condition.Parameter_Total loop
                  if T.To_String (Condition.Parameters (Index).Name) = "total"
                  then
                     Put_Note
                       (Item, "diagnostic.hint.context_total",
                        [Loc.Named
                           ("total",
                            T.Image (Condition.Parameters (Index).Int_Value))]);
                  end if;
               end loop;
            elsif Hint /= "" then
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

      --  The label coloured after the line is rendered, as Report does: a
      --  rendered argument has its control characters escaped, colour too.
      declare
         Line     : constant String :=
           Message (Item, "diagnostic.warning_line",
                    [Loc.Named ("severity", Severity), Loc.Named ("detail", Message (Item, Key, Arguments))]);
         At_Label : constant Natural := (if Severity = "" then 0 else Ada.Strings.Fixed.Index (Line, Severity));
      begin
         if Styles_Diagnostics (Item) and then At_Label > 0 then
            Error_Line (Item, Line (Line'First .. At_Label - 1)
                              & Terminal_Styles.Decorate (Severity, Terminal_Styles.Role_Warning)
                              & Line (At_Label + Severity'Length .. Line'Last));
         else
            Error_Line (Item, Line);
         end if;
      end;
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
      --  Set apart from the answer above it, and in groups: the tokens,
      --  how fast, where it ran, and how it ended.
      Put_Heading (Item, "statistics.heading", Diagnostic, Gap => True);
      Put_Heading (Item, "statistics.heading.tokens", Diagnostic);
      Put_Field
        (Item, "statistics.prompt_tokens",
         T.Image (Long_Long_Integer (Outcome.Prompt_Tokens)), Diagnostic);

      --  A prompt read mostly from a saved context: its rate is of the few
      --  tokens read, which said 0.11 tokens a second with nothing beside it
      --  to say why.
      if Outcome.Reused_Tokens > 0 then
         Put_Field
           (Item, "statistics.prompt_reused",
            T.Image (Long_Long_Integer (Outcome.Reused_Tokens)), Diagnostic);
      end if;
      Put_Field
        (Item, "statistics.generated_tokens",
         T.Image (Long_Long_Integer (Outcome.Generated_Tokens)), Diagnostic);
      Put_Field
        (Item, "statistics.context_position",
         T.Image (Long_Long_Integer (Outcome.Final_Position)), Diagnostic);
      Put_Field
        (Item, "statistics.context_size",
         T.Image (Long_Long_Integer (Outcome.Context_Size)), Diagnostic);
      Put_Field
        (Item, "statistics.seed", T.Image (Outcome.Seed), Diagnostic);
      Put_Heading (Item, "statistics.heading.speed", Diagnostic, Gap => True);
      Put_Field (Item, "statistics.prefill_duration", Seconds (Outcome.Prefill_Ns), Diagnostic);
      Put_Field (Item, "statistics.decode_duration", Seconds (Outcome.Decode_Ns), Diagnostic);
      Put_Field (Item, "statistics.prefill_rate", Rate (Outcome.Prefill_Rate), Diagnostic);
      Put_Field (Item, "statistics.decode_rate", Rate (Outcome.Decode_Rate), Diagnostic);
      --  What a draft model proposed and how much of it was taken, for a
      --  run that had one: the one number that says whether the draft was
      --  worth its own passes, in the colour of how it did.
      if Outcome.Drafted > 0 then
         Put_Field
           (Item, "statistics.drafted",
            T.Image (Long_Long_Integer (Outcome.Drafted)), Diagnostic);
         Put_Field
           (Item, "statistics.accepted",
            T.Image (Long_Long_Integer (Outcome.Accepted)) & " ("
            & T.Image (Long_Long_Integer (Outcome.Accepted * 100 / Outcome.Drafted)) & "%)",
            Diagnostic,
            (if Outcome.Accepted * 100 / Outcome.Drafted >= 60 then Good else Pending));
      end if;
      Put_Heading (Item, "statistics.heading.where", Diagnostic, Gap => True);
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
      --  What rewriting them at load cost, where they were rewritten.
      if Interfaces."/=" (Outcome.Repacked_Bytes, 0) then
         Put_Field
           (Item, "statistics.repacked",
            Message
              (Item, "statistics.repacked.value",
               [Loc.Named ("value", Size_Image (Outcome.Repacked_Bytes)),
                Loc.Named ("other", Seconds (Outcome.Repack_Ns))]),
            Diagnostic);
      end if;
      if Interfaces."/=" (Outcome.Panels_Cached, 0) then
         Put_Field
           (Item, "statistics.panels_cached",
            Size_Image (Outcome.Panels_Cached), Diagnostic);
      end if;
      if Outcome.Shifted > 0 then
         Put_Field
           (Item, "statistics.shifted",
            T.Image (Long_Long_Integer (Outcome.Shifted)), Diagnostic);
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
           (Item, "statistics.resident_bytes", Size_Image (Resident_Bytes), Diagnostic);
         Put_Field
           (Item, "statistics.given_back",
            T.Image (Long_Long_Integer (Given_Back)), Diagnostic, (if Given_Back > 0 then Pending else Plain));

         --  And whether the context is there as well as the weights. A
         --  device holding one and not the other attends on the processor,
         --  and nothing here used to say so.
         Put_Field
           (Item, "statistics.cached_bytes", Size_Image (Cached_Bytes), Diagnostic);

         --  And the rings, for a hybrid: said only where there are any,
         --  since every other architecture would read a nought there and
         --  wonder what it was.
         if Interfaces.">" (State_Bytes, 0) then
            Put_Field
              (Item, "statistics.state_bytes", Size_Image (State_Bytes), Diagnostic);
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

      Put_Heading (Item, "statistics.heading.ended", Diagnostic, Gap => True);
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

   overriding procedure Explain
     (Item   : in out Logprob_File_Reporter;
      Report : Model_Runner.Sampling.Explanation)
   is
      function Shown (Value : Model_Runner.Sampling.Real) return String
      is (T.Image (Long_Float (Value), 6));
   begin
      if not Ada.Text_IO.Is_Open (Item.File) then
         return;
      end if;

      Ada.Text_IO.Put
        (Item.File,
         "{""token"":" & T.Image (Long_Long_Integer (Report.Chosen))
         & ",""logprob"":" & Shown (Report.Log_Of) & ",""top"":[");
      for Index in 1 .. Report.Count loop
         Ada.Text_IO.Put
           (Item.File,
            (if Index > 1 then "," else "") & "["
            & T.Image (Long_Long_Integer (Report.Tokens (Index))) & ","
            & Shown (Report.Log_Values (Index)) & "]");
      end loop;
      Ada.Text_IO.Put_Line (Item.File, "]}");
   end Explain;

   procedure Open
     (Item : in out Logprob_File_Reporter;
      Path : String;
      Ok   : out Boolean) is
   begin
      Ada.Text_IO.Create (Item.File, Ada.Text_IO.Out_File, Path);
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Open;

   procedure Close (Item : in out Logprob_File_Reporter) is
   begin
      if Ada.Text_IO.Is_Open (Item.File) then
         Ada.Text_IO.Close (Item.File);
      end if;
   end Close;

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
