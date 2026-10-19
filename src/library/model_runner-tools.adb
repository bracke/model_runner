with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Strings.Maps;
with Ada.Unchecked_Deallocation;

with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;

with Model_Runner.Tools.Python_Calls;

package body Model_Runner.Tools is

   --  The most braces a reply's text is looked at for a call standing open
   --  in it: a call is among the first, and a reply that repeats "{" is
   --  read once, not once a brace.
   Most_Objects_Tried : constant := 64;

   package E renames Model_Runner.Errors;

   --  How deeply a value may nest. A tool's parameters are a schema and a
   --  schema nests as deeply as its author wrote it; this is where a file
   --  that nests without end stops being read.
   Max_Depth : constant := 32;

   --  What opens and closes a call in a reply. The template tells the model
   --  to write these, so they are the convention rather than a guess: a
   --  model that answers in another one wrote no call this can read.
   Call_Opens  : constant String := "<tool_call>";
   Call_Closes : constant String := "</tool_call>";

   --  What opens a call written as Python, and what closes it: a fenced
   --  block, as Gemma writes one. The block named tool_call is the same
   --  block, as Gemma's own instructions name it once.
   Code_Opens  : constant String := "```tool_code";
   Code_Named  : constant String := "```tool_call";
   Code_Closes : constant String := "```";

   procedure Free_Storage is
     new Ada.Unchecked_Deallocation (String, Storage_Access);

   ---------------------------------------------------------------------------
   --  Reading and writing JSON
   ---------------------------------------------------------------------------

   --  Skip whitespace, as JSON means it: the four characters and nothing
   --  else, so a file with a stray byte in it is refused rather than read
   --  past.
   function Blanks_Skipped (Text : String; From : Natural) return Natural is
      Index : Natural := From;
   begin
      while Index <= Text'Last
        and then (Text (Index) = ' '
                  or else Text (Index) = ASCII.HT
                  or else Text (Index) = ASCII.LF
                  or else Text (Index) = ASCII.CR)
      loop
         Index := Index + 1;
      end loop;
      return Index;
   end Blanks_Skipped;

   -------------
   -- Rewrite --
   -------------

   --  A value of a document written into Target after Last, in the
   --  spelling this engine uses: ", " between items, ": " after a name,
   --  members in the order written, a number as written, a string with its
   --  characters as they are and only the escapes JSON requires -- a quote,
   --  a backslash, a control as its short escape or as \u00XX. That is what
   --  the implementation these templates were made for writes, and a prompt
   --  differing from it in an escape is one the model was not trained on.
   procedure Write_Node
     (Document : Jsonlib.Documents.Document;
      Item     : Jsonlib.Documents.Node;
      Target   : in out String;
      Last     : in out Natural;
      Status   : in out E.Error_Info)
   is
      package Doc renames Jsonlib.Documents;

      --  Append to the target, reporting the one bound this has.
      procedure Emit (Value : String) is
      begin
         if E.Is_Error (Status) then
            return;
         elsif Last + Value'Length > Target'Length then
            Status := E.Make (E.Tools_Too_Large);
            E.Add_Integer (Status, "limit", Long_Long_Integer (Target'Length), E.Param_Bytes);
            return;
         end if;
         Target (Target'First + Last .. Target'First + Last + Value'Length - 1) := Value;
         Last := Last + Value'Length;
      end Emit;

      procedure Emit_String (Value : String) is
         Digits_16 : constant String := "0123456789abcdef";
      begin
         Emit ("""");
         for C of Value loop
            case C is
               when '"'      => Emit ("\""");
               when '\'      => Emit ("\\");
               when ASCII.BS => Emit ("\b");
               when ASCII.FF => Emit ("\f");
               when ASCII.LF => Emit ("\n");
               when ASCII.CR => Emit ("\r");
               when ASCII.HT => Emit ("\t");
               when Character'Val (0) .. Character'Val (7) | Character'Val (11)
                  | Character'Val (14) .. Character'Val (31) =>
                  Emit ("\u00" & Digits_16 (Digits_16'First + Character'Pos (C) / 16)
                        & Digits_16 (Digits_16'First + Character'Pos (C) mod 16));
               when others   => Emit ([1 => C]);
            end case;
         end loop;
         Emit ("""");
      end Emit_String;

      procedure Emit_Value (One : Doc.Node) is
      begin
         case Doc.Kind (Document, One) is
            when Doc.Null_Value    => Emit ("null");
            when Doc.Boolean_Value => Emit (if Doc.As_Boolean (Document, One) then "true" else "false");
            when Doc.Integer_Value | Doc.Float_Value => Emit (Doc.Literal (Document, One));
            when Doc.String_Value  => Emit_String (Doc.As_String (Document, One));
            when Doc.Array_Value =>
               Emit ("[");
               for Index in 1 .. Doc.Length (Document, One) loop
                  Emit ((if Index = 1 then "" else ", "));
                  Emit_Value (Doc.Element (Document, One, Index));
               end loop;
               Emit ("]");
            when Doc.Object_Value =>
               Emit ("{");
               for Index in 1 .. Doc.Length (Document, One) loop
                  Emit ((if Index = 1 then "" else ", "));
                  Emit_String (Doc.Name (Document, One, Index));
                  Emit (": ");
                  Emit_Value (Doc.Element (Document, One, Index));
               end loop;
               Emit ("}");
         end case;
      end Emit_Value;
   begin
      Emit_Value (Item);
   end Write_Node;

   --  Text read as JSON is read -- jsonlib, RFC 8259 exactly, every member
   --  as written -- or the refusal, saying where, in this engine's codes.
   procedure Parsed
     (Text     : String;
      Document : in out Jsonlib.Documents.Document;
      Status   : out E.Error_Info)
   is
      Error : Jsonlib.Errors.Error_Info;
   begin
      Status := E.Success;
      Jsonlib.Parsers.Parse
        (Text, Document, Error,
         (Jsonlib.Parsers.Default_Options with delta
            Max_Depth  => Max_Depth + 1,
            Duplicates => Jsonlib.Parsers.Keep_Duplicates));
      if Jsonlib.Errors.Failed (Error) then
         Status := E.Make
           ((if Jsonlib.Errors."=" (Error.Code, Jsonlib.Errors.Depth_Exceeded)
             then E.Tools_Nesting_Too_Deep else E.Tools_Invalid_JSON));
         E.Add_Integer (Status, "offset", Long_Long_Integer (Error.At_Position.Offset), E.Param_Offset);
      end if;
   end Parsed;

   procedure Rewrite
     (Text   : String;
      Target : out String;
      Last   : out Natural;
      Status : out E.Error_Info)
   is
      Document : Jsonlib.Documents.Document;
   begin
      Target := [others => ' '];
      Last := 0;
      Parsed (Text, Document, Status);
      if E.Is_Ok (Status) then
         Write_Node (Document, Jsonlib.Documents.Root (Document), Target, Last, Status);
      end if;
      if E.Is_Error (Status) then
         Last := 0;
      end if;
   end Rewrite;

   --  A model's JSON with the raw tabs and line breaks inside its strings
   --  written as the escapes they stand for. JSON allows none raw, and a
   --  definition with one is refused; but a model writing code into a call
   --  puts one there easily -- a tab copied from what it read -- and its
   --  call was dropped as no JSON at all.
   function Controls_Escaped (Text : String) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String;
      Inside : Boolean := False;
      Index  : Natural := Text'First;
   begin
      while Index <= Text'Last loop
         declare
            C : constant Character := Text (Index);
         begin
            if Inside and then C = '\' and then Index < Text'Last then
               Ada.Strings.Unbounded.Append (Result, Text (Index .. Index + 1));
               Index := Index + 1;
            elsif C = '"' then
               Inside := not Inside;
               Ada.Strings.Unbounded.Append (Result, C);
            elsif Inside and then C = ASCII.HT then
               Ada.Strings.Unbounded.Append (Result, "\t");
            elsif Inside and then C = ASCII.LF then
               Ada.Strings.Unbounded.Append (Result, "\n");
            elsif Inside and then C = ASCII.CR then
               Ada.Strings.Unbounded.Append (Result, "\r");
            else
               Ada.Strings.Unbounded.Append (Result, C);
            end if;
         end;
         Index := Index + 1;
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end Controls_Escaped;

   ---------------------------------------------------------------------------
   --  Reading what was written back
   ---------------------------------------------------------------------------

   --  Where the value at From ends, in text this engine wrote. Brackets are
   --  counted outside strings, which is enough here because what is being
   --  walked is not a caller's file but the spelling above.
   function Value_Ends (Text : String; From : Natural) return Natural is
      Index  : Natural := From;
      Opened : Natural := 0;
      Inside : Boolean := False;
   begin
      if From > Text'Last then
         return Text'Last;
      end if;

      case Text (From) is
         when '"' =>
            Index := From + 1;
            while Index <= Text'Last loop
               if Text (Index) = '\' then
                  Index := Index + 1;
               elsif Text (Index) = '"' then
                  return Index;
               end if;
               Index := Index + 1;
            end loop;
            return Text'Last;

         when '{' | '[' =>
            while Index <= Text'Last loop
               if Inside then
                  if Text (Index) = '\' then
                     Index := Index + 1;
                  elsif Text (Index) = '"' then
                     Inside := False;
                  end if;
               else
                  case Text (Index) is
                     when '"' =>
                        Inside := True;
                     when '{' | '[' =>
                        Opened := Opened + 1;
                     when '}' | ']' =>
                        Opened := Opened - 1;
                        if Opened = 0 then
                           return Index;
                        end if;
                     when others =>
                        null;
                  end case;
               end if;
               Index := Index + 1;
            end loop;
            return Text'Last;

         when others =>
            --  A number or one of the three words: it ends where the thing
            --  holding it goes on.
            while Index <= Text'Last
              and then Text (Index) /= ','
              and then Text (Index) /= '}'
              and then Text (Index) /= ']'
            loop
               Index := Index + 1;
            end loop;
            return Index - 1;
      end case;
   end Value_Ends;

   --  The value of one member of an object, as text. An empty string when
   --  the object does not carry it, which is what a caller asking after an
   --  optional member wants to hear.
   function Member (Object : String; Key : String) return String is
      Index : Natural := Blanks_Skipped (Object, Object'First);
   begin
      if Index > Object'Last or else Object (Index) /= '{' then
         return "";
      end if;

      Index := Blanks_Skipped (Object, Index + 1);
      while Index <= Object'Last and then Object (Index) = '"' loop
         declare
            Name_Ends : constant Natural := Value_Ends (Object, Index);
            Named     : constant String := Object (Index + 1 .. Name_Ends - 1);
            After     : Natural := Blanks_Skipped (Object, Name_Ends + 1);
         begin
            exit when After > Object'Last or else Object (After) /= ':';

            After := Blanks_Skipped (Object, After + 1);
            exit when After > Object'Last;

            declare
               Ends : constant Natural := Value_Ends (Object, After);
            begin
               if Named = Key then
                  return Object (After .. Ends);
               end if;
               Index := Blanks_Skipped (Object, Ends + 1);
               exit when Index > Object'Last or else Object (Index) /= ',';
               Index := Blanks_Skipped (Object, Index + 1);
            end;
         end;
      end loop;

      return "";
   end Member;

   --  A string as its characters rather than as JSON wrote them. The text
   --  this walks is text this engine wrote, so the escapes it can meet are
   --  the ones it writes.
   function Unquoted (Value : String) return String is
      Room  : String (1 .. Value'Length);
      Used  : Natural := 0;
      Index : Natural := Value'First + 1;
   begin
      if Value'Length < 2 or else Value (Value'First) /= '"' then
         return "";
      end if;

      while Index < Value'Last loop
         if Value (Index) = '\' and then Index + 1 <= Value'Last then
            Used := Used + 1;
            case Value (Index + 1) is
               when 'n'    => Room (Used) := ASCII.LF;
               when 't'    => Room (Used) := ASCII.HT;
               when 'r'    => Room (Used) := ASCII.CR;
               when 'b'    => Room (Used) := ASCII.BS;
               when 'f'    => Room (Used) := ASCII.FF;
               when others => Room (Used) := Value (Index + 1);
            end case;
            Index := Index + 2;
         else
            Used := Used + 1;
            Room (Used) := Value (Index);
            Index := Index + 1;
         end if;
      end loop;

      return Room (1 .. Used);
   end Unquoted;

   --  The name a definition or a call gives the function it is about, as
   --  either shape writes it: at the top level, or inside the "function"
   --  member that the shape callers usually write puts it in.
   function Named_Function (Object : String) return String is
      Inner : constant String := Member (Object, "function");
   begin
      if Inner /= "" and then Inner (Inner'First) = '{' then
         return Unquoted (Member (Inner, "name"));
      end if;
      return Unquoted (Member (Object, "name"));
   end Named_Function;

   -------------------
   -- Spoken_Length --
   -------------------

   function Spoken_Length (Reply : String) return Natural is
      Last : Natural := Reply'Last;
   begin
      for Start in Reply'First .. Reply'Last - Call_Opens'Length + 1 loop
         if Reply (Start .. Start + Call_Opens'Length - 1) = Call_Opens then
            Last := Start - 1;

            --  The newline a model writes between what it said and the
            --  first block it wrote belongs to neither: the template puts
            --  one there itself when there is something to separate.
            while Last >= Reply'First
              and then Reply (Last) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
            loop
               Last := Last - 1;
            end loop;

            return Last - Reply'First + 1;
         end if;
      end loop;

      --  A reply that called nothing is what it is, trailing space and all:
      --  this is not the place that decides what a plain answer looks like.
      return Reply'Length;
   end Spoken_Length;

   --------------------
   -- Harmony_Answer --
   --------------------

   function Harmony_Answer (Reply : String) return String is
      Open : Natural := 0;
      Shut : Natural;
   begin
      if Ada.Strings.Fixed.Index (Reply, Harmony_Channel) = 0 then
         return Reply;
      end if;

      for Start in Reply'First .. Reply'Last - Harmony_Final'Length + 1 loop
         if Reply (Start .. Start + Harmony_Final'Length - 1) = Harmony_Final
         then
            Open := Start + Harmony_Final'Length;
         end if;
      end loop;

      if Open = 0 then
         return "";
      end if;

      --  To the marker that ends the message -- <|end|>, or the <|return|>
      --  that ends the reply -- where the reply carries one.
      Shut := Ada.Strings.Fixed.Index (Reply (Open .. Reply'Last), "<|");
      return Reply (Open .. (if Shut = 0 then Reply'Last else Shut - 1));
   end Harmony_Answer;

   -----------------
   -- Spoken_Span --
   -----------------

   procedure Spoken_Span
     (Reply  : String;
      Syntax : Call_Syntax;
      First  : out Natural;
      Last   : out Natural)
   is
      Marker : constant String := ">>>";

      function Marks (Position : Natural) return Boolean
      is (Position + Marker'Length - 1 <= Reply'Last
          and then Reply (Position .. Position + Marker'Length - 1) = Marker);
   begin
      if Syntax = Python_Code then
         --  The prose before the first fenced call, or the whole reply
         --  when it wrote none -- and then a <tool_call> it wrote instead.
         First := Reply'First;
         for Start in Reply'First .. Reply'Last - Code_Opens'Length + 1 loop
            if Reply (Start .. Start + Code_Opens'Length - 1) in Code_Opens | Code_Named
            then
               Last := Start - 1;
               while Last >= Reply'First
                 and then Reply (Last) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
               loop
                  Last := Last - 1;
               end loop;
               return;
            end if;
         end loop;
         Last := Reply'First + Spoken_Length (Reply) - 1;
         return;
      end if;

      if Syntax in Function_XML | Qwen_XML | Mistral_Call
                  | DeepSeek_Fenced | DeepSeek_Plain
      then
         --  The prose before the first call as this syntax opens one: the
         --  <tool_call> envelope, or -- where a model writes its element
         --  bare, as MiniCPM always does and Qwen3-Coder now and then --
         --  the <function element itself; Mistral's [TOOL_CALLS]; the
         --  DeepSeek envelope or a call's own marker. Cut at the envelope
         --  alone, a MiniCPM reply was kept whole as its content and its
         --  calls attached as well, and the next prompt held each twice.
         First := Reply'First;
         Last  := Reply'First + Spoken_Length (Reply) - 1;
         declare
            function Marks_At (Position : Natural; Mark : String)
              return Boolean
            is (Position + Mark'Length - 1 <= Reply'Last
                and then Reply (Position .. Position + Mark'Length - 1)
                         = Mark);
         begin
            for Start in Reply'First .. Last loop
               if (Syntax = Qwen_XML and then Marks_At (Start, "<function="))
                 or else (Syntax = Function_XML
                          and then Marks_At (Start, "<function name="))
                 or else (Syntax = Mistral_Call
                          and then Marks_At (Start, Mistral_Calls))
                 or else (Syntax in DeepSeek_Fenced | DeepSeek_Plain
                          and then (Marks_At (Start, DeepSeek_Calls_Begin)
                                    or else Marks_At
                                              (Start, DeepSeek_Call_Begin)))
               then
                  Last := Start - 1;
                  while Last >= Reply'First
                    and then Reply (Last) in ' ' | ASCII.HT | ASCII.LF
                                           | ASCII.CR
                  loop
                     Last := Last - 1;
                  end loop;
                  return;
               end if;
            end loop;
         end;
         return;
      end if;

      if Syntax = Harmony_Call then
         --  The reasoning before the first call: the last analysis
         --  message's body that begins before it, to the marker after it.
         declare
            Call : constant Natural :=
              Ada.Strings.Fixed.Index (Reply, Harmony_Recipient);
            Upto : constant Natural :=
              (if Call = 0 then Reply'Last else Call - 1);
            Open : Natural := 0;
         begin
            First := Reply'First;
            Last  := Reply'First - 1;
            for Start in Reply'First .. Upto - Harmony_Analysis'Length + 1 loop
               if Reply (Start .. Start + Harmony_Analysis'Length - 1)
                  = Harmony_Analysis
               then
                  Open := Start + Harmony_Analysis'Length;
               end if;
            end loop;
            if Open /= 0 and then Open <= Upto then
               declare
                  Shut : constant Natural :=
                    Ada.Strings.Fixed.Index (Reply (Open .. Upto), "<|");
               begin
                  First := Open;
                  Last  := (if Shut = 0 then Upto else Shut - 1);
               end;
            end if;
         end;
         return;
      end if;

      --  The open form with no envelope: a call stands bare or fenced on a
      --  line of its own, and the prose is what comes before the first
      --  such line -- cut at the envelope alone, the object was kept as the
      --  turn's text and attached as its call, and the next prompt held it
      --  twice.
      if Syntax = Open_JSON and then Ada.Strings.Fixed.Index (Reply, Call_Opens) = 0 then
         First := Reply'First;
         Last  := Reply'Last;
         declare
            At_Line_Start : Boolean := True;

            --  Whether the object that opens at or soon after Start names a
            --  call, read to its own close: on its first line alone, a call
            --  written out over lines was taken for prose, and kept twice.
            function Names_Call (Start : Positive) return Boolean is
               Brace     : constant Natural :=
                 Ada.Strings.Fixed.Index (Reply (Start .. Natural'Min (Reply'Last, Start + 200)), "{");
               Depth     : Natural := 0;
               In_String : Boolean := False;
               Upto      : Natural := 0;
               P         : Natural := Brace;
            begin
               if Brace = 0 then
                  return False;
               end if;
               while P <= Natural'Min (Reply'Last, Brace + 8_000) loop
                  if In_String then
                     if Reply (P) = '\' then
                        P := P + 1;
                     elsif Reply (P) = '"' then
                        In_String := False;
                     end if;
                  elsif Reply (P) = '"' then
                     In_String := True;
                  elsif Reply (P) = '{' then
                     Depth := Depth + 1;
                  elsif Reply (P) = '}' then
                     Depth := Depth - 1;
                     if Depth = 0 then
                        Upto := P;
                        exit;
                     end if;
                  end if;
                  P := P + 1;
               end loop;
               return Upto /= 0 and then Ada.Strings.Fixed.Index (Reply (Brace .. Upto), """name""") > 0;
            end Names_Call;
         begin
            for Start in Reply'First .. Reply'Last loop
               --  A line that opens an object naming a call, or a fence whose
               --  object does: an object shown in the prose is the prose's.
               if At_Line_Start
                 and then ((Reply (Start) = '{' and then Names_Call (Start))
                           or else (Start + 2 <= Reply'Last and then Reply (Start .. Start + 2) = "```"
                                    and then Names_Call (Start)))
               then
                  Last := Start - 1;
                  while Last >= Reply'First and then Reply (Last) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
                     Last := Last - 1;
                  end loop;
                  return;
               end if;
               At_Line_Start :=
                 Reply (Start) = ASCII.LF or else (At_Line_Start and then Reply (Start) in ' ' | ASCII.HT);
            end loop;
         end;
         return;
      end if;

      if Syntax /= Recipient_JSON then
         --  The prose before the first block, as a span from the start.
         First := Reply'First;
         Last  := Reply'First + Spoken_Length (Reply) - 1;
         return;
      end if;

      --  The recipient form: what the model said is its ">>>all" block. Walk
      --  the ">>>"-parted blocks the way Read_Calls does and answer the body
      --  of the one whose recipient is "all"; answer an empty span when none
      --  said anything.
      First := Reply'First;
      Last  := Reply'First - 1;

      declare
         Pos : Natural := Reply'First;
      begin
         if Marks (Pos) then
            Pos := Pos + Marker'Length;
         end if;

         while Pos <= Reply'Last loop
            declare
               Name_Last : Natural := Pos;
            begin
               while Name_Last <= Reply'Last
                 and then Reply (Name_Last) /= ASCII.LF
               loop
                  Name_Last := Name_Last + 1;
               end loop;

               --  A recipient with no line break after it is a reply that
               --  stopped before its body; nothing to take.
               exit when Name_Last > Reply'Last;

               declare
                  Name       : constant String := Reply (Pos .. Name_Last - 1);
                  Body_First : constant Natural := Name_Last + 1;
                  Body_Last  : Natural := Body_First - 1;
               begin
                  while Body_Last + Marker'Length <= Reply'Last
                    and then not Marks (Body_Last + 1)
                  loop
                     Body_Last := Body_Last + 1;
                  end loop;
                  if Body_Last + Marker'Length > Reply'Last then
                     Body_Last := Reply'Last;
                  end if;

                  if Name = "all" or else Name = "all" & ASCII.CR then
                     First := Body_First;
                     Last  := Body_Last;

                     --  The newline before the next block, and any trailing
                     --  space, belong to neither: the template writes one
                     --  itself when there is something to separate.
                     while Last >= First
                       and then Reply (Last)
                                in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
                     loop
                        Last := Last - 1;
                     end loop;
                     return;
                  end if;

                  Pos := Body_Last + 1;
                  if Marks (Pos) then
                     Pos := Pos + Marker'Length;
                  end if;
               end;
            end;
         end loop;
      end;
   end Spoken_Span;

   ---------------------------------------------------------------------------
   --  Definitions
   ---------------------------------------------------------------------------

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Definitions) is
   begin
      if Item.Pool /= null then
         Item.Pool.all := [others => ' '];
         Free_Storage (Item.Pool);
      end if;
      Item.Rows := [others => <>];
      Item.Used := 0;
      Item.Filled := 0;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Definitions) is
   begin
      Close (Item);
   end Finalize;

   ----------
   -- Read --
   ----------

   procedure Read
     (Item   : in out Definitions;
      Text   : String;
      Status : out E.Error_Info)
   is
      package Doc renames Jsonlib.Documents;

      Document : Doc.Document;

      --  Write one definition into the pool and record where it went.
      procedure Take_One (One : Doc.Node) is
         Before : constant Natural := Item.Filled;
      begin
         if Item.Used = Max_Definitions then
            Status := E.Make (E.Tools_Too_Many);
            E.Add_Integer
              (Status, "limit", Long_Long_Integer (Max_Definitions));
            return;
         end if;

         if Doc."/=" (Doc.Kind (Document, One), Doc.Object_Value) then
            Status := E.Make (E.Tools_Not_An_Object);
            E.Add_Integer (Status, "offset", 0, E.Param_Offset);
            return;
         end if;

         Write_Node (Document, One, Item.Pool.all, Item.Filled, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         declare
            Written : constant String :=
              Item.Pool.all (Before + 1 .. Item.Filled);
            Called  : constant String := Named_Function (Written);
         begin
            if Called = "" then
               Status := E.Make (E.Tools_Missing_Name);
               E.Add_Integer
                 (Status, "index", Long_Long_Integer (Item.Used + 1));
               return;
            end if;

            --  The name is kept beside the definition rather than found
            --  again every time a call is matched against it.
            if Item.Filled + Called'Length > Item.Pool.all'Length then
               Status := E.Make (E.Tools_Too_Large);
               E.Add_Integer
                 (Status, "limit", Long_Long_Integer (Max_Definition_Bytes),
                  E.Param_Bytes);
               return;
            end if;

            Item.Pool.all (Item.Filled + 1 .. Item.Filled + Called'Length) :=
              Called;
            Item.Used := Item.Used + 1;
            Item.Rows (Item.Used) :=
              (Text => (Offset => Before, Length => Item.Filled - Before),
               Name => (Offset => Item.Filled, Length => Called'Length));
            Item.Filled := Item.Filled + Called'Length;
         end;
      end Take_One;

   begin
      Close (Item);
      Status := E.Success;

      Item.Pool := new String (1 .. Max_Definition_Bytes);
      Item.Pool.all := [others => ' '];

      --  Read as JSON is read, by jsonlib; then one object -- what a caller
      --  with one tool writes, and refusing would make them wrap -- or a
      --  list of them, an empty one offering nothing.
      Parsed (Text, Document, Status);
      if E.Is_Ok (Status) then
         declare
            Root : constant Doc.Node := Doc.Root (Document);
         begin
            if Doc."=" (Doc.Kind (Document, Root), Doc.Array_Value) then
               for Index in 1 .. Doc.Length (Document, Root) loop
                  Take_One (Doc.Element (Document, Root, Index));
                  exit when E.Is_Error (Status);
               end loop;
            else
               Take_One (Root);
            end if;
         end;
      end if;
      if E.Is_Error (Status) then
         Close (Item);
      end if;
   end Read;

   -----------
   -- Count --
   -----------

   function Count (Item : Definitions) return Natural is (Item.Used);

   ----------------
   -- Definition --
   ----------------

   function Definition (Item : Definitions; Index : Positive) return String is
   begin
      if Index > Item.Used or else Item.Pool = null then
         return "";
      end if;
      return Item.Pool.all
        (Item.Rows (Index).Text.Offset + 1
         .. Item.Rows (Index).Text.Offset + Item.Rows (Index).Text.Length);
   end Definition;

   ---------------
   -- Tool_Name --
   ---------------

   function Tool_Name (Item : Definitions; Index : Positive) return String is
   begin
      if Index > Item.Used or else Item.Pool = null then
         return "";
      end if;
      return Item.Pool.all
        (Item.Rows (Index).Name.Offset + 1
         .. Item.Rows (Index).Name.Offset + Item.Rows (Index).Name.Length);
   end Tool_Name;

   ------------
   -- Offers --
   ------------

   function Offers (Item : Definitions; Called : String) return Boolean is
   begin
      for Index in 1 .. Item.Used loop
         if Tool_Name (Item, Index) = Called then
            return True;
         end if;
      end loop;
      return False;
   end Offers;

   ---------------------------------------------------------------------------
   --  Calls
   ---------------------------------------------------------------------------

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Calls) is
   begin
      if Item.Pool /= null then
         Item.Pool.all := [others => ' '];
         Free_Storage (Item.Pool);
      end if;
      Item.Rows := [others => <>];
      Item.Used := 0;
      Item.Filled := 0;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Calls) is
   begin
      Close (Item);
   end Finalize;

   ----------------
   -- Read_Calls --
   ----------------

   procedure Read_Calls
     (Item   : in out Calls;
      Reply  : String;
      Status : out E.Error_Info;
      Syntax : Call_Syntax := Tool_Call_JSON;
      Offered : access constant Definitions'Class := null)
   is
      Index : Natural;

      --  Whether the reply carries Marker at Position.
      function Marks (Position : Natural; Marker : String) return Boolean
      is (Position + Marker'Length - 1 <= Reply'Last
          and then Reply (Position .. Position + Marker'Length - 1) = Marker);

      --  Keep one piece of text in the pool, answering where it went.
      procedure Keep (Value : String; Where : out Span) is
      begin
         Where := (Offset => Item.Filled, Length => Value'Length);
         if Item.Filled + Value'Length > Item.Pool.all'Length then
            Status := E.Make (E.Tools_Too_Large);
            E.Add_Integer
              (Status, "limit", Long_Long_Integer (Max_Call_Bytes),
               E.Param_Bytes);
            return;
         end if;
         Item.Pool.all (Item.Filled + 1 .. Item.Filled + Value'Length) := Value;
         Item.Filled := Item.Filled + Value'Length;
      end Keep;

      --  Read what one block holds.
      --  Announced is whether the text stood in an envelope: an announced
      --  call that does not read is malformed, while an object found
      --  standing open must carry both members to be a call at all, and
      --  is text otherwise -- Taken says which.
      procedure Take_One
        (Inner     : String;
         Announced : Boolean := True;
         Taken     : out Boolean)
      is
         Room    : String (1 .. Max_Call_Bytes);
         Written : Natural;
         Reading : E.Error_Info;
      begin
         Taken := False;
         if Item.Used = Max_Calls then
            Status := E.Make (E.Tools_Too_Many);
            E.Add_Integer (Status, "limit", Long_Long_Integer (Max_Calls));
            return;
         end if;

         Rewrite (Controls_Escaped (Inner), Room, Written, Reading);
         if E.Is_Error (Reading) then
            if Announced then
               Status := E.Make (E.Tools_Call_Malformed);
               E.Add_Integer
                 (Status, "index", Long_Long_Integer (Item.Used + 1));
            end if;
            return;
         end if;

         declare
            Object    : constant String := Room (1 .. Written);
            Called    : constant String := Named_Function (Object);
            --  The arguments under "arguments", or -- as Llama 3.1 and 3.2's
            --  own templates ask for them, and llama.cpp reads them -- under
            --  "parameters". Every call such a model wrote was printed as
            --  its answer and none ran.
            Named_Args : constant String := Member (Object, "arguments");
            Given      : constant String :=
              (if Named_Args /= "" then Named_Args
               else Member (Object, "parameters"));
            Name_At   : Span;
            Where     : Span;
         begin
            --  An object standing open is a call only where it names a tool
            --  on offer, when the caller said what was offered: one that a
            --  JSON answer holds, naming anything, is the answer's text.
            if Called = "" or else (not Announced and then Given = "")
              or else (not Announced and then Offered /= null
                       and then not Offers (Offered.all, Called))
            then
               if Announced then
                  Status := E.Make (E.Tools_Call_Malformed);
                  E.Add_Integer
                    (Status, "index", Long_Long_Integer (Item.Used + 1));
               end if;
               return;
            end if;

            Keep (Called, Name_At);
            if E.Is_Error (Status) then
               return;
            end if;

            if Given = "" then
               --  A call with no arguments is a call, and the model that
               --  wrote it meant an empty object.
               Keep ("{}", Where);
            elsif Given (Given'First) = '"' then
               --  Arguments written as a string holding JSON, which is how
               --  some models answer. Read back out of the string and
               --  written the one way, so that a caller sees the arguments
               --  and not the quoting.
               declare
                  Plain   : constant String := Unquoted (Given);
                  Room_2  : String (1 .. Max_Call_Bytes);
                  Used_2  : Natural;
                  Second  : E.Error_Info;
               begin
                  Rewrite (Plain, Room_2, Used_2, Second);
                  if E.Is_Error (Second) then
                     Status := E.Make (E.Tools_Call_Malformed);
                     E.Add_Integer
                       (Status, "index", Long_Long_Integer (Item.Used + 1));
                     return;
                  end if;
                  Keep (Room_2 (1 .. Used_2), Where);
               end;
            elsif Given (Given'First) = '{' then
               Keep (Given, Where);
            else
               Status := E.Make (E.Tools_Call_Malformed);
               E.Add_Integer
                 (Status, "index", Long_Long_Integer (Item.Used + 1));
               return;
            end if;

            if E.Is_Error (Status) then
               return;
            end if;

            Item.Used := Item.Used + 1;
            Item.Rows (Item.Used) := (Name => Name_At, Arguments => Where);
            Taken := True;
         end;
      end Take_One;

      --  The index of the brace that closes the object opened at Index,
      --  or zero when none does before the reply ends. Strings are
      --  stepped over, escapes and all, so a brace inside one is text.
      function Object_End (Index : Positive) return Natural is
         Depth     : Natural := 0;
         In_String : Boolean := False;
         P         : Positive := Index;
      begin
         while P <= Reply'Last loop
            if In_String then
               if Reply (P) = '\' then
                  P := P + 1;
               elsif Reply (P) = '"' then
                  In_String := False;
               end if;
            elsif Reply (P) = '"' then
               In_String := True;
            elsif Reply (P) = '{' then
               Depth := Depth + 1;
            elsif Reply (P) = '}' then
               Depth := Depth - 1;
               if Depth = 0 then
                  return P;
               end if;
            end if;
            P := P + 1;
         end loop;
         return 0;
      end Object_End;

      --  Store one call the arguments of which are already built as JSON,
      --  which is how the <function> form arrives.
      procedure Store (Name : String; Args : String) is
         Name_At, Args_At : Span;
      begin
         if Item.Used = Max_Calls then
            Status := E.Make (E.Tools_Too_Many);
            E.Add_Integer (Status, "limit", Long_Long_Integer (Max_Calls));
            return;
         end if;
         Keep (Name, Name_At);
         if E.Is_Error (Status) then
            return;
         end if;
         Keep (Args, Args_At);
         if E.Is_Error (Status) then
            return;
         end if;
         Item.Used := Item.Used + 1;
         Item.Rows (Item.Used) := (Name => Name_At, Arguments => Args_At);
      end Store;

      --  The next call's number on a malformed one.
      procedure Malformed is
      begin
         Status := E.Make (E.Tools_Call_Malformed);
         E.Add_Integer (Status, "index", Long_Long_Integer (Item.Used + 1));
      end Malformed;

      --  Store one call whose arguments are an object as the model wrote
      --  it: read as JSON and written the one way, or malformed.
      procedure Store_Object (Name : String; Object : String) is
         Room    : String (1 .. Max_Call_Bytes);
         Written : Natural;
         Reading : E.Error_Info;
      begin
         Rewrite (Controls_Escaped (Object), Room, Written, Reading);
         if E.Is_Error (Reading) then
            Malformed;
            return;
         end if;
         Store (Name, Room (1 .. Written));
      end Store_Object;

      --  Text without the space either side of it.
      function Trimmed (Text : String) return String is
         First : Natural := Text'First;
         Last  : Natural := Text'Last;
      begin
         while First <= Last
           and then Text (First) in ' ' | ASCII.LF | ASCII.CR | ASCII.HT
         loop
            First := First + 1;
         end loop;
         while Last >= First
           and then Text (Last) in ' ' | ASCII.LF | ASCII.CR | ASCII.HT
         loop
            Last := Last - 1;
         end loop;
         return Text (First .. Last);
      end Trimmed;

      --  Whether a recipient reads as a function's name: letters, digits
      --  and the few marks names carry, nothing else.
      function Is_Name (Text : String) return Boolean is
      begin
         if Text = "" then
            return False;
         end if;
         for C of Text loop
            if C not in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '.'
            then
               return False;
            end if;
         end loop;
         return True;
      end Is_Name;

      --  The value of the name="..." attribute at or after From, or "" when
      --  there is none before End_At.
      function Attribute_Name (From, End_At : Natural) return String is
         Key : constant String := "name=""";
         P   : Natural := From;
      begin
         while P + Key'Length - 1 <= End_At loop
            if Reply (P .. P + Key'Length - 1) = Key then
               declare
                  V : constant Natural := P + Key'Length;
                  Q : Natural := V;
               begin
                  while Q <= End_At and then Reply (Q) /= '"' loop
                     Q := Q + 1;
                  end loop;
                  if Q <= End_At then
                     return Reply (V .. Q - 1);
                  end if;
                  return "";
               end;
            end if;
            P := P + 1;
         end loop;
         return "";
      end Attribute_Name;

      --  A raw parameter value as a JSON string: any CDATA wrapper removed,
      --  then the characters JSON must not carry raw turned into escapes.
      function As_JSON_String (Raw : String) return String is
         Open  : constant String := "<![CDATA[";
         Close : constant String := "]]>";
         Inner : constant String :=
           (if Raw'Length >= Open'Length + Close'Length
              and then Raw (Raw'First .. Raw'First + Open'Length - 1) = Open
              and then Raw (Raw'Last - Close'Length + 1 .. Raw'Last) = Close
            then Raw (Raw'First + Open'Length .. Raw'Last - Close'Length)
            else Raw);
         Out_S : String (1 .. 2 + Inner'Length * 6);
         N     : Natural := 0;
         procedure Put (S : String) is
         begin
            Out_S (N + 1 .. N + S'Length) := S;
            N := N + S'Length;
         end Put;
      begin
         Put ("""");
         for C of Inner loop
            case C is
               when '"'      => Put ("\""");
               when '\'      => Put ("\\");
               when ASCII.LF => Put ("\n");
               when ASCII.CR => Put ("\r");
               when ASCII.HT => Put ("\t");
               when Character'Val (0) .. Character'Val (8)
                  | Character'Val (11) .. Character'Val (12)
                  | Character'Val (14) .. Character'Val (31) =>
                  declare
                     Hex : constant String := "0123456789abcdef";
                     Code : constant Natural := Character'Pos (C);
                  begin
                     Put ("\u00");
                     Put ([1 => Hex (Hex'First + Code / 16)]);
                     Put ([1 => Hex (Hex'First + Code mod 16)]);
                  end;
               when others   => Put ([1 => C]);
            end case;
         end loop;
         Put ("""");
         return Out_S (1 .. N);
      end As_JSON_String;

      --  Whether S is a JSON number, so a param value written as digits feeds
      --  a tool that wants a number rather than a quoted string.
      function Is_JSON_Number (S : String) return Boolean is
         I : Natural := S'First;
      begin
         if S'Length = 0 then
            return False;
         end if;
         if S (I) = '-' then
            I := I + 1;
         end if;
         if I > S'Last or else S (I) not in '0' .. '9' then
            return False;
         end if;
         --  A leading nought stands alone, as JSON has it: 0123 is no
         --  number, and written bare it made the arguments no JSON at all.
         if S (I) = '0' and then I < S'Last and then S (I + 1) in '0' .. '9'
         then
            return False;
         end if;
         while I <= S'Last and then S (I) in '0' .. '9' loop
            I := I + 1;
         end loop;
         if I <= S'Last and then S (I) = '.' then
            I := I + 1;
            if I > S'Last or else S (I) not in '0' .. '9' then
               return False;
            end if;
            while I <= S'Last and then S (I) in '0' .. '9' loop
               I := I + 1;
            end loop;
         end if;
         if I <= S'Last and then (S (I) = 'e' or else S (I) = 'E') then
            I := I + 1;
            if I <= S'Last and then (S (I) = '+' or else S (I) = '-') then
               I := I + 1;
            end if;
            if I > S'Last or else S (I) not in '0' .. '9' then
               return False;
            end if;
            while I <= S'Last and then S (I) in '0' .. '9' loop
               I := I + 1;
            end loop;
         end if;
         return I > S'Last;
      end Is_JSON_Number;

      --  The type the offered tool's schema gives a parameter: "string",
      --  "integer", "number", "boolean", "array", "object" or "null"; or
      --  empty where the tool is not offered, the parameter not described,
      --  or its type not one word.
      function Schema_Type (Tool, Key : String) return String is
      begin
         if Offered /= null then
            for Index in 1 .. Count (Offered.all) loop
               if Tool_Name (Offered.all, Index) = Tool then
                  return Python_Calls.Parameter_Type
                           (Definition (Offered.all, Index), Key);
               end if;
            end loop;
         end if;
         return "";
      end Schema_Type;

      --  A tag's value as the parameter's schema has it, as llama.cpp reads
      --  the same tags: a string parameter's text is a string whatever it
      --  looks like -- a version "3.10", a file holding "42", a flag named
      --  "true" -- and a number, a boolean, a list or an object the JSON the
      --  model wrote for it, where it is that. Where the schema says
      --  nothing, the text's own look decides, as before: a number, true,
      --  false or null bare, anything else a string. A list a Qwen wrote in
      --  a tag was taken for a string holding one, and refused; a string
      --  that looked like a number reached the tool as a number.
      --  What JSON takes around a value: spaces, tabs and line ends.
      Spaces : constant Ada.Strings.Maps.Character_Set :=
        Ada.Strings.Maps.To_Set
          (" " & ASCII.HT & ASCII.LF & ASCII.CR);

      --  Anything but a string is read as JSON is, its spaces around it
      --  no part of it: a "42" written on a line of its own between other
      --  spaces than the one line break either side stayed the string
      --  " 42 ", which the tool's schema refused.
      function As_Typed_Value (Tool, Key, Raw : String) return String is
         Kind : constant String := Schema_Type (Tool, Key);
         Bare : constant String :=
           Ada.Strings.Fixed.Trim (Raw, Spaces, Spaces);
      begin
         if Kind = "string" then
            return As_JSON_String (Raw);
         elsif Kind in "array" | "object" then
            if Bare /= "" and then Bare (Bare'First) in '[' | '{' then
               declare
                  Room    : String (1 .. Max_Call_Bytes);
                  Written : Natural;
                  Reading : E.Error_Info;
               begin
                  Rewrite (Controls_Escaped (Bare), Room, Written, Reading);
                  if E.Is_Ok (Reading) then
                     return Room (1 .. Written);
                  end if;
               end;
            end if;
            return As_JSON_String (Raw);
         elsif Kind in "integer" | "number" then
            return (if Is_JSON_Number (Bare) then Bare
                    else As_JSON_String (Raw));
         elsif Kind = "boolean" then
            return (if Bare in "true" | "false" then Bare
                    else As_JSON_String (Raw));
         elsif Kind = "null" then
            return (if Bare = "null" then Bare else As_JSON_String (Raw));
         end if;
         return (if Bare in "true" | "false" | "null"
                   or else Is_JSON_Number (Bare)
                 then Bare else As_JSON_String (Raw));
      end As_Typed_Value;

      --  Read one <function ...> ... </function> block into a call: its name
      --  from the function's attribute, its arguments from a JSON object
      --  built of the <param name="p">v</param> children.
      procedure Take_Function (First, Last : Natural) is
         Head_End : Natural := First;
         Args     : String (1 .. Max_Call_Bytes);
         A_Len    : Natural := 0;
         P        : Natural;
         Count    : Natural := 0;

         --  Past the room, noted and not written: a value of quotes and
         --  line breaks grows as JSON, and its write ran past Args.
         Overflowed : Boolean := False;

         procedure Add (S : String) is
         begin
            if A_Len + S'Length > Args'Length then
               Overflowed := True;
               return;
            end if;
            Args (A_Len + 1 .. A_Len + S'Length) := S;
            A_Len := A_Len + S'Length;
         end Add;
      begin
         --  The function's opening tag ends at the first '>'.
         while Head_End <= Last and then Reply (Head_End) /= '>' loop
            Head_End := Head_End + 1;
         end loop;
         declare
            Name : constant String := Attribute_Name (First, Head_End);
         begin
            if Name = "" then
               Status := E.Make (E.Tools_Call_Malformed);
               E.Add_Integer
                 (Status, "index", Long_Long_Integer (Item.Used + 1));
               return;
            end if;

            Add ("{");
            P := Head_End + 1;
            while P <= Last loop
               if P + 6 <= Last and then Reply (P .. P + 5) = "<param" then
                  declare
                     Tag_End : Natural := P;
                     Key     : constant String := Attribute_Name (P, Last);
                     V_First : Natural;
                     V_Last  : Natural;
                  begin
                     while Tag_End <= Last and then Reply (Tag_End) /= '>' loop
                        Tag_End := Tag_End + 1;
                     end loop;
                     V_First := Tag_End + 1;
                     V_Last  := V_First - 1;
                     while V_Last + 8 <= Last
                       and then Reply (V_Last + 1 .. V_Last + 8) /= "</param>"
                     loop
                        V_Last := V_Last + 1;
                     end loop;
                     if Key /= "" then
                        if Count > 0 then
                           Add (", ");
                        end if;
                        Add (As_JSON_String (Key));
                        Add (": ");
                        Add (As_Typed_Value
                               (Name, Key,
                                (if V_Last >= V_First
                                 then Reply (V_First .. V_Last) else "")));
                        Count := Count + 1;
                     end if;
                     P := V_Last + 1;
                  end;
               else
                  P := P + 1;
               end if;
            end loop;
            Add ("}");
            if Overflowed then
               Status := E.Make (E.Tools_Too_Large);
               E.Add_Integer (Status, "limit", Long_Long_Integer (Max_Call_Bytes), E.Param_Bytes);
               return;
            end if;
            Store (Name, Args (1 .. A_Len));
         end;
      end Take_Function;

      --  Read one <function=NAME> ... </function> block, Qwen3-Coder's form:
      --  the name after the '=', and each <parameter=ARG> ... </parameter>
      --  whose value stands on its own lines. The line break either side
      --  of the value is dropped and it is written back as its schema's
      --  type.
      procedure Take_Qwen (First, Last : Natural) is
         Args  : String (1 .. Max_Call_Bytes);
         A_Len : Natural := 0;
         P     : Natural;
         Count : Natural := 0;

         --  Past the room, noted and not written: a value of quotes and
         --  line breaks grows as JSON, and its write ran past Args.
         Overflowed : Boolean := False;

         procedure Add (S : String) is
         begin
            if A_Len + S'Length > Args'Length then
               Overflowed := True;
               return;
            end if;
            Args (A_Len + 1 .. A_Len + S'Length) := S;
            A_Len := A_Len + S'Length;
         end Add;

         --  The text after the first '=' up to the next '>', which is the
         --  name in <function=NAME> and <parameter=ARG>.
         function After_Equals (From, Stop : Natural) return String is
            Eq : Natural := From;
         begin
            while Eq <= Stop and then Reply (Eq) /= '=' loop
               Eq := Eq + 1;
            end loop;
            if Eq >= Stop then
               return "";
            end if;
            declare
               V : constant Natural := Eq + 1;
               Q : Natural := V;
            begin
               while Q <= Stop and then Reply (Q) /= '>' loop
                  Q := Q + 1;
               end loop;
               return Reply (V .. Q - 1);
            end;
         end After_Equals;

         Head_End : Natural := First;
      begin
         while Head_End <= Last and then Reply (Head_End) /= '>' loop
            Head_End := Head_End + 1;
         end loop;
         declare
            Name : constant String := After_Equals (First, Head_End);
         begin
            if Name = "" then
               Status := E.Make (E.Tools_Call_Malformed);
               E.Add_Integer
                 (Status, "index", Long_Long_Integer (Item.Used + 1));
               return;
            end if;

            Add ("{");
            P := Head_End + 1;
            while P <= Last loop
               if P + 10 <= Last and then Reply (P .. P + 9) = "<parameter"
               then
                  declare
                     Tag_End : Natural := P;
                     V_First : Natural;
                     V_Last  : Natural;
                  begin
                     while Tag_End <= Last and then Reply (Tag_End) /= '>' loop
                        Tag_End := Tag_End + 1;
                     end loop;
                     declare
                        Key : constant String := After_Equals (P, Tag_End);
                     begin
                        V_First := Tag_End + 1;
                        V_Last  := V_First - 1;
                        while V_Last + 12 <= Last
                          and then Reply (V_Last + 1 .. V_Last + 12)
                                   /= "</parameter>"
                        loop
                           V_Last := V_Last + 1;
                        end loop;
                        --  Never closed: the value runs to the call's end, not
                        --  to eleven short of it.
                        if V_Last + 12 > Last then
                           V_Last := Last;
                        end if;
                        P := V_Last + 1;

                        --  The value stands on its own lines: the one line
                        --  break after the tag and the one before its close
                        --  are the form's, and go, as llama.cpp reads them;
                        --  everything else is the value's own. All the
                        --  whitespace went once, and an edit's indented
                        --  passage lost its indent and matched nothing.
                        if V_First <= V_Last and then Reply (V_First) = ASCII.CR
                          and then V_First < V_Last
                          and then Reply (V_First + 1) = ASCII.LF
                        then
                           V_First := V_First + 2;
                        elsif V_First <= V_Last
                          and then Reply (V_First) = ASCII.LF
                        then
                           V_First := V_First + 1;
                        end if;
                        if V_Last >= V_First and then Reply (V_Last) = ASCII.LF
                        then
                           V_Last := V_Last - 1;
                           if V_Last >= V_First
                             and then Reply (V_Last) = ASCII.CR
                           then
                              V_Last := V_Last - 1;
                           end if;
                        end if;
                        if Key /= "" then
                           if Count > 0 then
                              Add (", ");
                           end if;
                           Add (As_JSON_String (Key));
                           Add (": ");
                           Add (As_Typed_Value
                                  (Name, Key,
                                   (if V_Last >= V_First
                                    then Reply (V_First .. V_Last) else "")));
                           Count := Count + 1;
                        end if;
                     end;
                  end;
               else
                  P := P + 1;
               end if;
            end loop;
            Add ("}");
            if Overflowed then
               Status := E.Make (E.Tools_Too_Large);
               E.Add_Integer (Status, "limit", Long_Long_Integer (Max_Call_Bytes), E.Param_Bytes);
               return;
            end if;
            Store (Name, Args (1 .. A_Len));
         end;
      end Take_Qwen;

      --  The first closed call block that would not read, the rest read.
      Bad : E.Error_Info := E.Success;
   begin
      Close (Item);
      Status := E.Success;

      Item.Pool := new String (1 .. Max_Call_Bytes);
      Item.Pool.all := [others => ' '];

      case Syntax is
      when Tool_Call_JSON | Open_JSON =>
         Index := Reply'First;
         while Index <= Reply'Last loop
            if Marks (Index, Call_Opens) then
               declare
                  First : constant Natural := Index + Call_Opens'Length;
                  Shut  : Natural := First;
                  Brace : Natural := First;
               begin
                  --  Where the block's object closes, when it holds one: its
                  --  strings may spell the closing tag -- a call writing a
                  --  file about calls -- and the first tag cut it there.
                  while Brace <= Reply'Last and then Reply (Brace) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
                     Brace := Brace + 1;
                  end loop;
                  if Brace <= Reply'Last and then Reply (Brace) = '{' and then Object_End (Brace) > 0 then
                     Shut := Object_End (Brace) + 1;
                  end if;
                  while Shut <= Reply'Last and then not Marks (Shut, Call_Closes)
                  loop
                     Shut := Shut + 1;
                  end loop;

                  if Shut > Reply'Last then
                     --  A block that never closes is a reply that stopped in
                     --  the middle of a call, which is worth saying rather
                     --  than reading as no call at all.
                     Status := E.Make (E.Tools_Call_Malformed);
                     E.Add_Integer
                       (Status, "index", Long_Long_Integer (Item.Used + 1));
                     return;
                  end if;

                  declare
                     Taken : Boolean;
                  begin
                     Take_One (Reply (First .. Shut - 1), Taken => Taken);
                  end;
                  if E.Is_Error (Status) and then E."=" (Status.Code, E.Tools_Call_Malformed) then
                     if E.Is_Ok (Bad) then
                        Bad := Status;
                     end if;
                     Status := E.Success;
                  elsif E.Is_Error (Status) then
                     return;
                  end if;

                  Index := Shut + Call_Closes'Length;
               end;
            else
               Index := Index + 1;
            end if;
         end loop;
         --  A closed block that would not read is said once the rest are
         --  read: stopped at it, a whole call after it was dropped unsaid.
         if E.Is_Error (Bad) then
            Status := Bad;
            return;
         end if;

         --  The shapes a model trained on no envelope writes: an object
         --  standing open in the text, bare or fenced. Looked for only when
         --  no envelope was found, so that a reply which did write the
         --  envelope is not read twice, and taken only when the object reads
         --  as JSON and names a function with arguments; anything else at a
         --  brace is text, and the search moves on one character.
         if Syntax = Open_JSON and then Item.Used = 0 then
            Index := Reply'First;
            declare
               --  Braces looked at: each that is not a call is read to its
               --  close, or to the reply's end, and a reply gone round on
               --  "{" took a scan of the rest for every one of them.
               Tried : Natural := 0;
            begin
               while Index <= Reply'Last and then Tried < Most_Objects_Tried loop
                  if Reply (Index) = '{' then
                     Tried := Tried + 1;
                     declare
                        Shut  : constant Natural := Object_End (Index);
                        Taken : Boolean := False;
                     begin
                        if Shut > 0 then
                           Take_One (Reply (Index .. Shut), Announced => False,
                                     Taken => Taken);
                           if E.Is_Error (Status) then
                              return;
                           end if;
                        end if;
                        Index := (if Taken then Shut + 1 else Index + 1);
                     end;
                  else
                     Index := Index + 1;
                  end if;
               end loop;
            end;
         end if;

         --  The same call dressed as the offer was: a <name> and then its
         --  <arguments> object, as a model that saw its tools inside <tools>
         --  writes them back. Read only where nothing else was, and only an
         --  object that closes where its tag says.
         if Syntax = Open_JSON and then Item.Used = 0 then
            declare
               Name_Opens : constant String := "<name>";
               Name_Shuts : constant String := "</name>";
               Args_Opens : constant String := "<arguments>";
               Args_Shuts : constant String := "</arguments>";

               --  Where a mark next appears from a place, or 0.
               function Next (Mark : String; From : Positive) return Natural is
               begin
                  for At_Index in From .. Reply'Last loop
                     if Marks (At_Index, Mark) then
                        return At_Index;
                     end if;
                  end loop;
                  return 0;
               end Next;

               function Trimmed (Text : String) return String
               is (Ada.Strings.Fixed.Trim
                     (Text, Ada.Strings.Maps.To_Set (" " & ASCII.LF & ASCII.CR & ASCII.HT),
                      Ada.Strings.Maps.To_Set (" " & ASCII.LF & ASCII.CR & ASCII.HT)));
            begin
               Index := Reply'First;
               while Index <= Reply'Last loop
                  declare
                     N_Open : constant Natural := Next (Name_Opens, Index);
                     N_Shut : constant Natural :=
                       (if N_Open = 0 then 0 else Next (Name_Shuts, N_Open));
                     A_Open : constant Natural :=
                       (if N_Shut = 0 then 0 else Next (Args_Opens, N_Shut));
                     A_Shut : constant Natural :=
                       (if A_Open = 0 then 0 else Next (Args_Shuts, A_Open));
                  begin
                     exit when A_Shut = 0;
                     declare
                        Name : constant String :=
                          Trimmed (Reply (N_Open + Name_Opens'Length .. N_Shut - 1));
                        Args : constant String :=
                          Trimmed (Reply (A_Open + Args_Opens'Length .. A_Shut - 1));
                     begin
                        --  Between the name and its arguments only space.
                        if Name /= "" and then Args'Length >= 2
                          and then Args (Args'First) = '{' and then Args (Args'Last) = '}'
                          and then Trimmed (Reply (N_Shut + Name_Shuts'Length .. A_Open - 1)) = ""
                          and then (Offered = null or else Offers (Offered.all, Name))
                        then
                           --  As JSON reads it, written the one way: kept as it
                           --  stood, an object that did not read went to the
                           --  tool as its arguments.
                           declare
                              Room    : String (1 .. Max_Call_Bytes);
                              Written : Natural;
                              Reading : E.Error_Info;
                           begin
                              Rewrite (Controls_Escaped (Args), Room, Written, Reading);
                              if E.Is_Ok (Reading) then
                                 Store (Name, Room (1 .. Written));
                                 if E.Is_Error (Status) then
                                    return;
                                 end if;
                              end if;
                           end;
                        end if;
                     end;
                     Index := A_Shut + Args_Shuts'Length;
                  end;
               end loop;
            end;
         end if;

      when Function_XML =>
         declare
            Open_Tag  : constant String := "<function";
            Close_Tag : constant String := "</function>";
         begin
            Index := Reply'First;
            while Index <= Reply'Last loop
               --  The tag, not a word it begins: prose that speaks of
               --  <functions> was read as a call never closed, and every call
               --  of the reply was dropped.
               if Marks (Index, Open_Tag) and then Index + Open_Tag'Length <= Reply'Last
                 and then Reply (Index + Open_Tag'Length) in ' ' | '>'
               then
                  declare
                     Shut : Natural := Index;
                  begin
                     while Shut <= Reply'Last
                       and then not Marks (Shut, Close_Tag)
                     loop
                        Shut := Shut + 1;
                     end loop;
                     if Shut > Reply'Last then
                        Status := E.Make (E.Tools_Call_Malformed);
                        E.Add_Integer
                          (Status, "index",
                           Long_Long_Integer (Item.Used + 1));
                        return;
                     end if;
                     Take_Function (Index, Shut - 1);
                     if E.Is_Error (Status) then
                        return;
                     end if;
                     Index := Shut + Close_Tag'Length;
                  end;
               else
                  Index := Index + 1;
               end if;
            end loop;
         end;

      when Qwen_XML =>
         declare
            Open_Tag  : constant String := "<function=";
            Close_Tag : constant String := "</function>";
            Param_Opens : constant String := "<parameter=";
            Param_Shuts : constant String := "</parameter>";
         begin
            Index := Reply'First;
            while Index <= Reply'Last loop
               if Marks (Index, Open_Tag) then
                  declare
                     Shut : Natural := Index;
                  begin
                     --  Each parameter's text stepped over to its close: a
                     --  file's content may spell </function>, and the call
                     --  was cut there, its content written short.
                     while Shut <= Reply'Last
                       and then not Marks (Shut, Close_Tag)
                     loop
                        if Marks (Shut, Param_Opens) then
                           declare
                              --  Not past where the call ends: a </function> the
                              --  envelope's close, the next call, or the reply's
                              --  end follows -- a parameter left open swallowed
                              --  the call after it, and one whose text spells
                              --  </tool_call> must still be read whole.
                              function Call_End return Natural is
                                 Look : Natural := Shut;
                              begin
                                 loop
                                    declare
                                       Found : constant Natural :=
                                         (if Look > Reply'Last then 0
                                          else Ada.Strings.Fixed.Index (Reply (Look .. Reply'Last), Close_Tag));
                                       After : Natural := Found + Close_Tag'Length;
                                    begin
                                       exit when Found = 0;
                                       while After <= Reply'Last
                                         and then Reply (After) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
                                       loop
                                          After := After + 1;
                                       end loop;
                                       if After > Reply'Last or else Marks (After, "</tool_call>")
                                         or else Marks (After, "<tool_call>") or else Marks (After, Open_Tag)
                                       then
                                          return Found - 1;
                                       end if;
                                       Look := Found + 1;
                                    end;
                                 end loop;
                                 return Reply'Last;
                              end Call_End;
                              Bound : constant Natural := Call_End;
                              Param_End : constant Natural :=
                                Ada.Strings.Fixed.Index (Reply (Shut .. Bound), Param_Shuts);
                           begin
                              Shut := (if Param_End = 0 then Shut + 1 else Param_End + Param_Shuts'Length);
                           end;
                        else
                           Shut := Shut + 1;
                        end if;
                     end loop;
                     if Shut > Reply'Last then
                        Status := E.Make (E.Tools_Call_Malformed);
                        E.Add_Integer
                          (Status, "index",
                           Long_Long_Integer (Item.Used + 1));
                        return;
                     end if;
                     Take_Qwen (Index, Shut - 1);
                     if E.Is_Error (Status) then
                        return;
                     end if;
                     Index := Shut + Close_Tag'Length;
                  end;
               else
                  Index := Index + 1;
               end if;
            end loop;
         end;

      when Python_Code =>
         --  Gemma's form: each ```tool_code block holds one or more calls
         --  written as Python, read into a name and a JSON object. A reply
         --  with no such block is read as the open JSON a model trained on
         --  no envelope writes, since a Gemma now and then writes that
         --  instead.
         Index := Reply'First;
         while Index <= Reply'Last loop
            if Marks (Index, Code_Opens) or else Marks (Index, Code_Named) then
               --  Read call by call up to the fence that closes the block,
               --  not to the first "```": an edit's text may hold one.
               declare
                  Rest      : constant String :=
                    Reply (Index + Code_Opens'Length .. Reply'Last);
                  From      : Positive := Rest'First;
                  Name      : String (1 .. 256);
                  Name_Last : Natural;
                  Args      : String (1 .. Max_Call_Bytes);
                  Args_Last : Natural;
                  Found     : Boolean;
                  Read      : Boolean;
               begin
                  loop
                     Python_Calls.Read_Call
                       (Rest, From, Name, Name_Last, Args, Args_Last,
                        Found, Read, Offered);
                     exit when not Found;
                     if not Read then
                        Status := E.Make (E.Tools_Call_Malformed);
                        E.Add_Integer
                          (Status, "index", Long_Long_Integer (Item.Used + 1));
                        return;
                     end if;
                     declare
                        Room    : String (1 .. Max_Call_Bytes);
                        Written : Natural;
                        Reading : E.Error_Info;
                     begin
                        Rewrite (Args (1 .. Args_Last), Room, Written, Reading);
                        if E.Is_Error (Reading) then
                           Status := E.Make (E.Tools_Call_Malformed);
                           E.Add_Integer
                             (Status, "index", Long_Long_Integer (Item.Used + 1));
                           return;
                        end if;
                        Store (Name (1 .. Name_Last), Room (1 .. Written));
                     end;
                     if E.Is_Error (Status) then
                        return;
                     end if;
                  end loop;

                  --  A block that never closes is a reply that stopped in
                  --  the middle of a call.
                  if not Marks (From, Code_Closes) then
                     Status := E.Make (E.Tools_Call_Malformed);
                     E.Add_Integer
                       (Status, "index", Long_Long_Integer (Item.Used + 1));
                     return;
                  end if;
                  Index := From + Code_Closes'Length;
               end;
            else
               Index := Index + 1;
            end if;
         end loop;

         if Item.Used = 0 then
            --  Held to what was offered, as the open form always is: a bare
            --  object in prose naming any tool was taken for a call.
            Read_Calls (Item, Reply, Status, Open_JSON, Offered => Offered);
         end if;

      when Recipient_JSON =>
         --  Functionary's recipient form. The reply is a run of blocks, each
         --  a recipient and a body separated by a line break, the blocks
         --  parted by ">>>". A recipient of "all" is what the model said and
         --  is not a call; any other names a function and its body is the
         --  arguments object. The generation prompt ends with ">>>", so the
         --  first block usually stands without one and the rest carry it.
         declare
            Marker : constant String := ">>>";
            Pos    : Natural := Reply'First;
         begin
            if Marks (Pos, Marker) then
               Pos := Pos + Marker'Length;
            end if;

            while Pos <= Reply'Last loop
               declare
                  Name_Last : Natural := Pos;
               begin
                  while Name_Last <= Reply'Last
                    and then Reply (Name_Last) /= ASCII.LF
                  loop
                     Name_Last := Name_Last + 1;
                  end loop;

                  --  A recipient with no line break after it is a reply that
                  --  stopped before its body; nothing to read.
                  exit when Name_Last > Reply'Last;

                  declare
                     --  The recipient as written, a CR before the line break
                     --  dropped: "all\r" is "all".
                     Name       : constant String :=
                       Reply (Pos .. (if Name_Last - 1 >= Pos
                                        and then Reply (Name_Last - 1)
                                                 = ASCII.CR
                                      then Name_Last - 2
                                      else Name_Last - 1));
                     Body_First : constant Natural := Name_Last + 1;
                     Body_Last  : Natural := Body_First - 1;
                  begin
                     while Body_Last + Marker'Length <= Reply'Last
                       and then not Marks (Body_Last + 1, Marker)
                     loop
                        Body_Last := Body_Last + 1;
                     end loop;
                     if Body_Last + Marker'Length > Reply'Last then
                        Body_Last := Reply'Last;
                     end if;

                     --  A recipient is a tool on offer, where the caller said
                     --  what was offered, and a name in any case: ">>> import
                     --  os" in prose the grammar did not hold is prose.
                     if Name /= "all" and then Is_Name (Name)
                       and then (Offered = null
                                 or else Offers (Offered.all, Name))
                     then
                        declare
                           Open : Natural := Body_First;
                        begin
                           while Open <= Body_Last
                             and then Reply (Open) /= '{'
                           loop
                              Open := Open + 1;
                           end loop;

                           if Open > Body_Last then
                              --  A named recipient with no object is a call
                              --  with no arguments.
                              Store (Name, "{}");
                           else
                              declare
                                 Shut : constant Natural := Object_End (Open);
                              begin
                                 if Shut = 0 then
                                    Status := E.Make (E.Tools_Call_Malformed);
                                    E.Add_Integer
                                      (Status, "index",
                                       Long_Long_Integer (Item.Used + 1));
                                    return;
                                 end if;
                                 declare
                                    Room    : String (1 .. Max_Call_Bytes);
                                    Written : Natural;
                                    Reading : E.Error_Info;
                                 begin
                                    Rewrite (Controls_Escaped (Reply (Open .. Shut)),
                                             Room, Written, Reading);
                                    if E.Is_Error (Reading) then
                                       Status :=
                                         E.Make (E.Tools_Call_Malformed);
                                       E.Add_Integer
                                         (Status, "index",
                                          Long_Long_Integer (Item.Used + 1));
                                       return;
                                    end if;
                                    Store (Name, Room (1 .. Written));
                                 end;
                              end;
                           end if;
                           if E.Is_Error (Status) then
                              return;
                           end if;
                        end;
                     end if;

                     Pos := Body_Last + 1;
                     if Marks (Pos, Marker) then
                        Pos := Pos + Marker'Length;
                     end if;
                  end;
               end;
            end loop;
         end;

      when Harmony_Call =>
         --  gpt-oss's harmony form: a call is a message whose header names
         --  its recipient -- "to=functions.NAME", before the channel or
         --  after it -- and whose body, after <|message|>, is the
         --  arguments object, up to the <|call|> that ends generation.
         Index := Reply'First;
         while Index <= Reply'Last loop
            if Marks (Index, Harmony_Recipient) then
               declare
                  Name_First : constant Positive :=
                    Index + Harmony_Recipient'Length;
                  Name_Last  : Natural := Name_First - 1;
                  Body_At    : Natural;
               begin
                  while Name_Last < Reply'Last
                    and then Reply (Name_Last + 1)
                             in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9'
                              | '_' | '-'
                  loop
                     Name_Last := Name_Last + 1;
                  end loop;

                  Body_At := Ada.Strings.Fixed.Index
                    (Reply (Name_Last + 1 .. Reply'Last), Harmony_Message);

                  declare
                     Name : constant String := Reply (Name_First .. Name_Last);
                  begin
                     if Name = "" or else Body_At = 0 then
                        --  A header that stopped before its body is a
                        --  reply cut off in the middle of a call.
                        Malformed;
                        return;
                     end if;

                     Body_At := Body_At + Harmony_Message'Length;

                     if Offered /= null and then not Offers (Offered.all, Name)
                     then
                        Index := Body_At;
                     else
                        declare
                           Open : Natural := Body_At;
                        begin
                           while Open <= Reply'Last
                             and then Reply (Open) in ' ' | ASCII.LF
                                                    | ASCII.CR | ASCII.HT
                           loop
                              Open := Open + 1;
                           end loop;

                           if Open > Reply'Last or else Reply (Open) /= '{'
                           then
                              Store (Name, "{}");
                              Index := Open;
                           else
                              declare
                                 Shut : constant Natural := Object_End (Open);
                              begin
                                 if Shut = 0 then
                                    Malformed;
                                    return;
                                 end if;
                                 Store_Object (Name, Reply (Open .. Shut));
                                 Index := Shut + 1;
                              end;
                           end if;
                        end;
                        if E.Is_Error (Status) then
                           return;
                        end if;
                     end if;
                  end;
               end;
            else
               Index := Index + 1;
            end if;
         end loop;

      when Mistral_Call =>
         --  Mistral's own: [TOOL_CALLS] before each call, the name, [ARGS]
         --  and the arguments object -- as Mistral Small 3.2, Devstral and
         --  Magistral write them and llama.cpp reads them. The older form,
         --  [TOOL_CALLS] and a list of {"name": .., "arguments": ..}
         --  objects, is read too.
         Index := Reply'First;
         while Index <= Reply'Last loop
            if Marks (Index, Mistral_Calls) then
               declare
                  P : Natural := Index + Mistral_Calls'Length;
               begin
                  while P <= Reply'Last
                    and then Reply (P) in ' ' | ASCII.LF | ASCII.CR | ASCII.HT
                  loop
                     P := P + 1;
                  end loop;

                  if P <= Reply'Last and then Reply (P) = '[' then
                     --  The list: each object in it a call.
                     P := P + 1;
                     loop
                        while P <= Reply'Last and then Reply (P) /= '{'
                          and then Reply (P) /= ']'
                        loop
                           P := P + 1;
                        end loop;
                        exit when P > Reply'Last or else Reply (P) = ']';
                        declare
                           Shut  : constant Natural := Object_End (P);
                           Taken : Boolean;
                        begin
                           if Shut = 0 then
                              Malformed;
                              return;
                           end if;
                           Take_One (Reply (P .. Shut), Taken => Taken);
                           if E.Is_Error (Status) then
                              return;
                           end if;
                           P := Shut + 1;
                        end;
                     end loop;
                     Index := P;
                  else
                     declare
                        Name_First : constant Natural := P;
                        Name_Last  : Natural := P;
                     begin
                        while Name_Last <= Reply'Last
                          and then not Marks (Name_Last, Mistral_Args)
                          and then not Marks (Name_Last, Mistral_Calls)
                        loop
                           Name_Last := Name_Last + 1;
                        end loop;
                        if Name_Last > Reply'Last
                          or else not Marks (Name_Last, Mistral_Args)
                        then
                           Malformed;
                           return;
                        end if;
                        declare
                           Name : constant String :=
                             Trimmed (Reply (Name_First .. Name_Last - 1));
                           Open : Natural := Name_Last + Mistral_Args'Length;
                        begin
                           while Open <= Reply'Last
                             and then Reply (Open) in ' ' | ASCII.LF
                                                    | ASCII.CR | ASCII.HT
                           loop
                              Open := Open + 1;
                           end loop;
                           if Name = "" or else Open > Reply'Last
                             or else Reply (Open) /= '{'
                           then
                              Malformed;
                              return;
                           end if;
                           declare
                              Shut : constant Natural := Object_End (Open);
                           begin
                              if Shut = 0 then
                                 Malformed;
                                 return;
                              end if;
                              Store_Object (Name, Reply (Open .. Shut));
                              if E.Is_Error (Status) then
                                 return;
                              end if;
                              Index := Shut + 1;
                           end;
                        end;
                     end;
                  end if;
               end;
            else
               Index := Index + 1;
            end if;
         end loop;

      when DeepSeek_Fenced | DeepSeek_Plain =>
         --  DeepSeek's: each call between its own markers, inside the
         --  calls' envelope. R1 and V3 write the call's kind, the
         --  separator, the name on a line of its own and the arguments in a
         --  ```json fence; V3.1 writes the name, the separator and the
         --  arguments. Either is read in either syntax, as one reader: what
         --  stands before the separator says which.
         Index := Reply'First;
         while Index <= Reply'Last loop
            if Marks (Index, DeepSeek_Call_Begin) then
               declare
                  First : constant Natural :=
                    Index + DeepSeek_Call_Begin'Length;
                  Shut  : Natural := First;
                  Sep   : Natural := 0;
               begin
                  while Shut <= Reply'Last
                    and then not Marks (Shut, DeepSeek_Call_End)
                  loop
                     if Sep = 0 and then Marks (Shut, DeepSeek_Sep) then
                        Sep := Shut;
                     end if;
                     Shut := Shut + 1;
                  end loop;
                  if Shut > Reply'Last or else Sep = 0 then
                     Malformed;
                     return;
                  end if;

                  declare
                     Before : constant String :=
                       Trimmed (Reply (First .. Sep - 1));
                     After  : constant Natural := Sep + DeepSeek_Sep'Length;
                     Line   : Natural := After;
                     Open   : Natural;
                  begin
                     if Before = "function" then
                        while Line < Shut and then Reply (Line) /= ASCII.LF
                        loop
                           Line := Line + 1;
                        end loop;
                        Open := Line;
                     else
                        Open := After;
                     end if;
                     while Open < Shut and then Reply (Open) /= '{' loop
                        Open := Open + 1;
                     end loop;

                     declare
                        Name : constant String :=
                          (if Before = "function"
                           then Trimmed (Reply (After .. Line - 1))
                           else Before);
                        Last_Brace : constant Natural :=
                          (if Open < Shut then Object_End (Open) else 0);
                     begin
                        if Name = "" then
                           Malformed;
                           return;
                        end if;
                        if Open >= Shut then
                           Store (Name, "{}");
                        elsif Last_Brace = 0 or else Last_Brace >= Shut then
                           Malformed;
                           return;
                        else
                           Store_Object (Name, Reply (Open .. Last_Brace));
                        end if;
                        if E.Is_Error (Status) then
                           return;
                        end if;
                     end;
                  end;
                  Index := Shut + DeepSeek_Call_End'Length;
               end;
            else
               Index := Index + 1;
            end if;
         end loop;
      end case;
   exception
      when others =>
         Close (Item);
         Status := E.Make (E.Internal_Invariant_Violated);
         E.Add_Frame (Status, "tools.read_calls");
   end Read_Calls;

   -----------
   -- Count --
   -----------

   function Count (Item : Calls) return Natural is (Item.Used);

   ------------
   -- Called --
   ------------

   function Called (Item : Calls; Index : Positive) return String is
   begin
      if Index > Item.Used or else Item.Pool = null then
         return "";
      end if;
      return Item.Pool.all
        (Item.Rows (Index).Name.Offset + 1
         .. Item.Rows (Index).Name.Offset + Item.Rows (Index).Name.Length);
   end Called;

   ---------------
   -- Arguments --
   ---------------

   function Arguments (Item : Calls; Index : Positive) return String is
   begin
      if Index > Item.Used or else Item.Pool = null then
         return "";
      end if;
      return Item.Pool.all
        (Item.Rows (Index).Arguments.Offset + 1
         .. Item.Rows (Index).Arguments.Offset
            + Item.Rows (Index).Arguments.Length);
   end Arguments;

end Model_Runner.Tools;
