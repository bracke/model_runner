separate (Model_Runner.Templates.Compile)
procedure Read_Bare_Term
  (Text   : String;
   From   : in out Natural;
   Result : out Term;
   Ok     : out Boolean)
is
   Index : Natural := Skip_Spaces (Text, From);
begin
   Result := (others => <>);
   Ok := False;

   if Index > Text'Last then
      return;
   end if;

   --  A bracketed group holding one value, which is a term with
   --  brackets round it and reads as that term: what follows the
   --  closing bracket is written after the group and applies to what
   --  is in it, which is how a template writes
   --  (text.split(marker)|last).lstrip('\n'). A group holding a sum
   --  is not a term and is read where an operand is. A bracket
   --  holding a comma at its own level is a tuple, read below.
   if Text (Index) = '(' and then not Is_Tuple_At (Text, Index) then
      declare
         Shut  : constant Natural := Closes_At (Text, Index);
         Inner : Operand;
         Read  : Boolean;
      begin
         if Shut = 0 or else Group_Depth >= Max_Depth then
            return;
         end if;

         declare
            Held : constant String := Text (Index + 1 .. Shut - 1);
            Scan : Natural := Held'First;
         begin
            Group_Depth := Group_Depth + 1;
            Read_Operand (Held, Scan, Inner, Read);
            Group_Depth := Group_Depth - 1;

            if not Read
              or else Inner.Count /= 1
              or else Skip_Spaces (Held, Scan) <= Held'Last
            then
               return;
            end if;
         end;

         --  A term with filters on it is kept as a group, so that
         --  what follows the bracket -- "(x | first).name" -- is
         --  applied after the filters and not before them.
         if Inner.Terms (1).Filtered > 0 then
            declare
               Kept : Natural;
            begin
               Keep (Inner, Kept);
               if Kept = 0 then
                  return;
               end if;
               Result := (others => <>);
               Result.Kind := Term_Group;
               Result.Offset := Kept;
               Result.Numeric := Sums (Inner);
            end;
         else
            Result := Inner.Terms (1);
         end if;
         Result.Join := Join_Plus;
         From := Shut + 1;
         Ok := True;
         return;
      end;
   end if;

   --  A list written out: its elements are operands, kept one after
   --  another, and the list is made of what they are worth when it
   --  is read. Empty is a list too, which is what a template writes
   --  to say it was given no tools.
   --  And a tuple, ("number", "integer"): a bracket holding a comma
   --  at its own level, read as the list of its elements -- what a
   --  template does with one is ask "in" of it or walk it, and a list
   --  answers both the same. A bracket without such a comma is a
   --  group, read where groups are.
   if Text (Index) = '['
     or else (Text (Index) = '(' and then Is_Tuple_At (Text, Index))
   then
      declare
         Opener : constant Character := Text (Index);
         Closer : constant Character :=
           (if Opener = '[' then ']' else ')');
         Shut   : Natural := Index + 1;
         Level  : Natural := 0;
         Quote  : Character := ' ';
      begin
         while Shut <= Text'Last loop
            if Quote /= ' ' then
               if Text (Shut) = Quote then
                  Quote := ' ';
               end if;
            elsif Text (Shut) in ''' | '"' then
               Quote := Text (Shut);
            elsif Text (Shut) = Opener then
               Level := Level + 1;
            elsif Text (Shut) = Closer then
               exit when Level = 0;
               Level := Level - 1;
            end if;
            Shut := Shut + 1;
         end loop;
         if Shut > Text'Last then
            return;
         end if;

         --  Read first and kept after, all in a row: an element that
         --  is itself a list keeps its own elements as it is read,
         --  and those must not land between this list's.
         declare
            Inside : constant String := Text (Index + 1 .. Shut - 1);
            Scan   : Natural := Inside'First;
            Given  : Natural := 0;
            Start  : Natural := 0;
            Held   : Operand_List;
         begin
            while Skip_Spaces (Inside, Scan) <= Inside'Last loop
               declare
                  Read  : Boolean;
                  Next  : Natural;
               begin
                  if Given >= Max_Literal_Elements then
                     --  Refused where it is read, by name: a list
                     --  longer than this engine holds is outside
                     --  the subset and says so, rather than leaving
                     --  the expression around it unreadable.
                     Result := Refused (Text (Index .. Shut));
                     From := Shut + 1;
                     Ok := True;
                     return;
                  end if;
                  Given := Given + 1;
                  Read_Operand (Inside, Scan, Held (Given), Read);
                  if not Read then
                     return;
                  end if;
                  Next := Skip_Spaces (Inside, Scan);
                  if Next <= Inside'Last then
                     if Inside (Next) /= ',' then
                        return;
                     end if;
                     Scan := Next + 1;
                  else
                     Scan := Next;
                  end if;
               end;
            end loop;
            for Which in 1 .. Given loop
               declare
                  Kept : Natural;
               begin
                  Keep (Held (Which), Kept);
                  if Kept = 0 then
                     return;
                  end if;
                  if Start = 0 then
                     Start := Kept;
                  end if;
               end;
            end loop;
            Result.Kind := Term_List;
            Result.Index_At := Start;
            Result.Length := Given;
            --  A tuple is a list that prints as one: Offset says so.
            Result.Offset := (if Opener = '(' then 1 else 0);
            From := Shut + 1;
            Ok := True;
            return;
         end;
      end;
   end if;

   --  A mapping written out: pairs of a key and a value, each an
   --  operand, kept alternately.
   if Text (Index) = '{' then
      declare
         Shut   : Natural := Index + 1;
         Level  : Natural := 0;
         Quote  : Character := ' ';
      begin
         while Shut <= Text'Last loop
            if Quote /= ' ' then
               if Text (Shut) = Quote then
                  Quote := ' ';
               end if;
            elsif Text (Shut) in ''' | '"' then
               Quote := Text (Shut);
            elsif Text (Shut) in '{' | '[' | '(' then
               Level := Level + 1;
            elsif Text (Shut) in '}' | ']' | ')' then
               exit when Level = 0 and then Text (Shut) = '}';
               Level := (if Level > 0 then Level - 1 else 0);
            end if;
            Shut := Shut + 1;
         end loop;
         if Shut > Text'Last then
            return;
         end if;

         declare
            Inside : constant String := Text (Index + 1 .. Shut - 1);
            Scan   : Natural := Inside'First;
            Pairs  : Natural := 0;
            Start  : Natural := 0;
            Held   : Operand_List;
         begin
            while Skip_Spaces (Inside, Scan) <= Inside'Last loop
               declare
                  Read  : Boolean;
                  Next  : Natural;
               begin
                  if 2 * Pairs + 2 > Max_Literal_Elements then
                     Result := Refused (Text (Index .. Shut));
                     From := Shut + 1;
                     Ok := True;
                     return;
                  end if;
                  Read_Operand (Inside, Scan, Held (2 * Pairs + 1), Read);
                  if not Read then
                     return;
                  end if;
                  Next := Skip_Spaces (Inside, Scan);
                  if Next > Inside'Last or else Inside (Next) /= ':' then
                     return;
                  end if;
                  Scan := Next + 1;
                  Read_Operand (Inside, Scan, Held (2 * Pairs + 2), Read);
                  if not Read then
                     return;
                  end if;
                  Pairs := Pairs + 1;
                  Next := Skip_Spaces (Inside, Scan);
                  if Next <= Inside'Last then
                     if Inside (Next) /= ',' then
                        return;
                     end if;
                     Scan := Next + 1;
                  else
                     Scan := Next;
                  end if;
               end;
            end loop;
            for Which in 1 .. 2 * Pairs loop
               declare
                  Kept : Natural;
               begin
                  Keep (Held (Which), Kept);
                  if Kept = 0 then
                     return;
                  end if;
                  if Start = 0 then
                     Start := Kept;
                  end if;
               end;
            end loop;
            Result.Kind := Term_Dict;
            Result.Index_At := Start;
            Result.Length := Pairs;
            From := Shut + 1;
            Ok := True;
            return;
         end;
      end;
   end if;

   if Text (Index) = ''' or else Text (Index) = '"' then
      declare
         Quote   : constant Character := Text (Index);
         Decoded : String (1 .. Text'Length);
         Filled  : Natural := 0;
         Stored  : Boolean;
      begin
         Index := Index + 1;
         while Index <= Text'Last and then Text (Index) /= Quote loop
            if Text (Index) = '\' and then Index < Text'Last then
               Index := Index + 1;
               Filled := Filled + 1;
               case Text (Index) is
                  when 'n'    => Decoded (Filled) := ASCII.LF;
                  when 't'    => Decoded (Filled) := ASCII.HT;
                  when 'r'    => Decoded (Filled) := ASCII.CR;
                  when others => Decoded (Filled) := Text (Index);
               end case;
            else
               Filled := Filled + 1;
               Decoded (Filled) := Text (Index);
            end if;
            Index := Index + 1;
         end loop;

         if Index > Text'Last then
            return;
         end if;

         Index := Index + 1;
         Result.Kind := Term_Literal;
         Store_Literal
           (Decoded (1 .. Filled), Result.Offset, Result.Length, Stored);
         Ok := Stored;
         From := Index;
         return;
      end;
   end if;

   --  A number, with a sign where it carries one. The sign is part of
   --  the number and not an operator: a template counting backwards
   --  writes range(n, -1, -1), and reading the minus as subtraction
   --  there would be reading two of the three numbers as one.
   if Text (Index) in '0' .. '9'
     or else (Text (Index) = '-'
              and then Index < Text'Last
              and then Text (Index + 1) in '0' .. '9')
   then
      declare
         Start  : constant Natural := Index;
         Stored : Boolean;
      begin
         if Text (Index) = '-' then
            Index := Index + 1;
         end if;
         while Index <= Text'Last and then Text (Index) in '0' .. '9' loop
            Index := Index + 1;
         end loop;

         --  A fraction and an exponent, where the number has them:
         --  1.5, 2.5e-3. The point needs a digit after it, so that
         --  a number in front of a member's name stays two things.
         if Index < Text'Last and then Text (Index) = '.'
           and then Text (Index + 1) in '0' .. '9'
         then
            Index := Index + 1;
            while Index <= Text'Last and then Text (Index) in '0' .. '9'
            loop
               Index := Index + 1;
            end loop;
         end if;
         if Index < Text'Last and then Text (Index) in 'e' | 'E'
           and then (Text (Index + 1) in '0' .. '9'
                     or else (Text (Index + 1) in '+' | '-'
                              and then Index + 1 < Text'Last
                              and then Text (Index + 2) in '0' .. '9'))
         then
            Index := Index + 2;
            while Index <= Text'Last and then Text (Index) in '0' .. '9'
            loop
               Index := Index + 1;
            end loop;
         end if;

         Result.Kind := Term_Literal;
         Result.Numeric := True;
         Store_Literal
           (Text (Start .. Index - 1), Result.Offset, Result.Length,
            Stored);
         Ok := Stored;
         From := Index;
         return;
      end;
   end if;

   declare
      First, Last : Natural;
   begin
      From := Index;
      Read_Word (Text, From, First, Last);
      if Last < First then
         return;
      end if;

      declare
         Word : constant String := Text (First .. Last);
         Tail : Natural := Skip_Spaces (Text, From);

         --  Where a method's name begins inside the word, or zero.
         --  Read_Word takes a dotted name whole, so "a.b.strip" comes
         --  back as one word and the method has to be cut off it here
         --  rather than read as a token of its own.
         function Method_At (Suffix : String) return Natural is
         begin
            if Word'Length > Suffix'Length
              and then Word (Word'Last - Suffix'Length + 1 .. Word'Last)
                       = Suffix
            then
               return Word'Last - Suffix'Length + 1;
            end if;
            return 0;
         end Method_At;

         Cut   : Natural := 0;
         Doing : Method_Kind := Method_None;
      begin
         --  What the word ends with, longest first: rstrip and lstrip
         --  both end in strip.
         for Named of Method_Names loop
            if Cut = 0 then
               Cut := Method_At (Named.Text.all);
               if Cut /= 0 then
                  Doing := Named.Kind;
               end if;
            end if;
         end loop;

         --  A method is called: a word ending in a method's name
         --  with no brackets after it is a member of that name --
         --  a schema's "items" -- and is read as a path below.
         if Doing /= Method_None
           and then Tail <= Text'Last and then Text (Tail) = '('
         then
            declare
               Head  : constant String := Word (Word'First .. Cut - 1);
               Inner : Natural := Head'First;
               Taken : Boolean;
            begin
               if Head'Length = 0 then
                  return;
               end if;

               --  What the method is applied to, read as a term of its
               --  own so that a method on a message's content and a
               --  method on a name are the same thing said twice.
               Read_Bare_Term (Head, Inner, Result, Taken);
               if not Taken
                 or else Skip_Spaces (Head, Inner) <= Head'Last
               then
                  Result := Refused (Head);
                  Ok := True;
                  return;
               end if;

               Add_Method (Text, Doing, From, Result, Ok);
               return;
            end;
         end if;

         --  A macro the template defined, called with its arguments.
         --  The arguments are operands, kept one after another so
         --  that the term can name them by the first and a count.
         if Tail <= Text'Last and then Text (Tail) = '('
           and then (Macro_Named (Word) /= 0 or else Word = "caller")
         then
            declare
               Shut   : constant Natural := Closes_At (Text, Tail);
               Inside : constant String :=
                 (if Shut = 0 then "" else Text (Tail + 1 .. Shut - 1));
               Cursor_At     : Natural := Inside'First;
               Given  : Natural := 0;
               Start  : Natural := 0;
            begin
               if Shut = 0 then
                  return;
               end if;
               --  Each argument a whole expression, up to the next
               --  comma at the top level; read first and kept
               --  after, all in a row, for the reason a list's
               --  elements are.
               declare
                  Held  : Operand_List;
               begin
                  while Skip_Spaces (Inside, Cursor_At) <= Inside'Last
                  loop
                     declare
                        Stop : constant Natural :=
                          Comma_After (Inside, Cursor_At);
                        Read : Boolean;
                        Value_From : Natural :=
                          Skip_Spaces (Inside, Cursor_At);
                        Key_First, Key_Last : Natural;
                        Equals : Natural;
                        Keyword : Boolean := False;
                     begin
                        --  name=value: the name kept as an operand of
                        --  its own, the value after it.
                        Read_Word (Inside, Value_From, Key_First,
                                   Key_Last);
                        Equals := Skip_Spaces (Inside, Value_From);
                        if Key_Last >= Key_First
                          and then Is_Plain_Name
                                     (Inside (Key_First .. Key_Last))
                          and then Equals < Stop - 1
                          and then Inside (Equals) = '='
                          and then Inside (Equals + 1) /= '='
                        then
                           Keyword := True;
                           Value_From := Equals + 1;
                        else
                           Value_From := Cursor_At;
                        end if;

                        if Given + (if Keyword then 2 else 1)
                             > 2 * Max_Parameters
                          or else Given + (if Keyword then 2 else 1)
                             > Max_Literal_Elements
                        then
                           Result := Refused (Text (First .. Shut));
                           From := Shut + 1;
                           Ok := True;
                           return;
                        end if;
                        if Keyword then
                           declare
                              Key    : Term :=
                                (Kind => Term_Keyword, others => <>);
                              Stored : Boolean;
                           begin
                              Store_Literal
                                (Inside (Key_First .. Key_Last),
                                 Key.Offset, Key.Length, Stored);
                              if not Stored then
                                 return;
                              end if;
                              Given := Given + 1;
                              Held (Given) :=
                                (Terms => [1 => Key, others => <>],
                                 Count => 1);
                           end;
                        end if;
                        Given := Given + 1;
                        Read_Expression
                          (Inside (Value_From .. Stop - 1), Held (Given),
                           Read);
                        if not Read then
                           Result := Refused (Text (First .. Shut));
                           From := Shut + 1;
                           Ok := True;
                           return;
                        end if;
                        Cursor_At := Stop + 1;
                     end;
                  end loop;
                  for Which in 1 .. Given loop
                     declare
                        Kept : Natural;
                     begin
                        Keep (Held (Which), Kept);
                        if Kept = 0 then
                           return;
                        end if;
                        if Start = 0 then
                           Start := Kept;
                        end if;
                     end;
                  end loop;
               end;
               Result.Kind := Term_Macro;
               Result.Offset := Macro_Named (Word);
               Result.Index_At := Start;
               Result.Length := Given;
               From := Shut + 1;
               Ok := True;
               return;
            end;
         end if;

         --  The two functions a template calls: strftime_now for the
         --  date and raise_exception to refuse. Each takes one quoted
         --  argument, kept as a literal; anything else in the
         --  brackets refuses the term where it is read.
         if (Word = "strftime_now" or else Word = "raise_exception")
           and then Tail <= Text'Last and then Text (Tail) = '('
         then
            declare
               Shut     : constant Natural := Closes_At (Text, Tail);
               Argument : Term;
               Scan     : Natural;
               Taken    : Boolean := False;
            begin
               if Shut = 0 then
                  return;
               end if;
               Scan := Tail + 1;
               Read_Bare_Term (Text (Tail + 1 .. Shut - 1), Scan,
                               Argument, Taken);
               if Taken and then Argument.Kind = Term_Literal
                 and then Skip_Spaces (Text (Tail + 1 .. Shut - 1),
                                       Scan) > Shut - 1
               then
                  Result.Kind :=
                    (if Word = "strftime_now" then Term_Now
                     else Term_Raise);
                  Result.Offset := Argument.Offset;
                  Result.Length := Argument.Length;
               else
                  Result := Refused (Text (First .. Shut));
               end if;
               From := Shut + 1;
               Ok := True;
               return;
            end;
         end if;

         --  message['role'] and message['content'] use bracket syntax;
         --  message.role and message.content use dotted syntax. Both are
         --  accepted because real templates use both.
         if Word = "message" and then Tail <= Text'Last
           and then Text (Tail) = '['
         then
            declare
               Close_Bracket : Natural := Tail;
            begin
               while Close_Bracket <= Text'Last
                 and then Text (Close_Bracket) /= ']'
               loop
                  Close_Bracket := Close_Bracket + 1;
               end loop;
               if Close_Bracket > Text'Last then
                  return;
               end if;

               declare
                  Field : constant String :=
                    Model_Runner.Text.Trim (Text (Tail + 1 .. Close_Bracket - 1));
               begin
                  if Field = "'role'" or else Field = """role""" then
                     Result.Kind := Term_Message_Role;
                  elsif Field = "'content'" or else Field = """content"""
                  then
                     Result.Kind := Term_Message_Content;
                  elsif Field = "'tool_calls'"
                    or else Field = """tool_calls"""
                  then
                     Result.Kind := Term_Message_Calls;
                  elsif Field'Length > 2
                    and then (Field (Field'First) = '''
                              or else Field (Field'First) = '"')
                    and then Field (Field'Last) = Field (Field'First)
                    and then Is_Plain_Name
                               (Field (Field'First + 1
                                       .. Field'Last - 1))
                  then
                     --  Any other field, read as message.NAME reads
                     --  it: what the message holds is known when the
                     --  render reads it, and a field it does not have
                     --  is undefined there, as in jinja2. Templates
                     --  ask message['reasoning_content'] and
                     --  message['prefix'] this way, and were refused.
                     declare
                        Stored : Boolean;
                     begin
                        Result.Kind := Term_Variable;
                        Result.Offset := Slot_Of ("message");
                        Store_Literal
                          (Field (Field'First + 1 .. Field'Last - 1),
                           Result.Path_At, Result.Path_Len, Stored);
                        if Result.Offset = 0 or else not Stored then
                           Result :=
                             Refused (Text (First .. Close_Bracket));
                        end if;
                     end;
                  else
                     return;
                  end if;
               end;
               From := Close_Bracket + 1;
               Ok := True;
               return;
            end;
         end if;

         --  A message named by position: messages[0]['role'],
         --  messages[0].role, and the same with a position the
         --  template works out rather than writes. Templates use it to
         --  ask whether the conversation already opens with a system
         --  message, and to look at the message beside this one.
         if Word /= "message" and then From <= Text'Last
           and then Text (From) = '['
         then
            declare
               Shut  : Natural := From + 1;
               Level : Natural := 0;
            begin
               while Shut <= Text'Last loop
                  if Text (Shut) = '[' then
                     Level := Level + 1;
                  elsif Text (Shut) = ']' then
                     exit when Level = 0;
                     Level := Level - 1;
                  end if;
                  Shut := Shut + 1;
               end loop;

               if Shut > Text'Last then
                  return;
               end if;

               declare
                  Inside : constant String :=
                    Model_Runner.Text.Trim (Text (From + 1 .. Shut - 1));
                  Where  : Natural := Inside'First;
                  Index  : Operand;
                  Taken  : Boolean;
                  Kept   : Natural;
                  After  : Natural := Shut + 1;
                  Field  : Natural := 0;
               begin
                  --  A slice is written the same way as far as the
                  --  opening bracket and is not an index at all: it
                  --  is a cut, read as a method of the name in front
                  --  of it. Leaving here rather than refusing is what
                  --  lets the name be read as a name and the cut as
                  --  what follows it.
                  if Inside'Length = 0
                    or else (for some Letter of Inside => Letter = ':')
                  then
                     goto Not_A_Position;
                  end if;

                  Read_Operand (Inside, Where, Index, Taken);
                  if not Taken
                    or else Skip_Spaces (Inside, Where) <= Inside'Last
                  then
                     return;
                  end if;

                  --  Which field, written either way round: a bracket
                  --  with a quoted name in it, or a dot and the name.
                  --  A message of a list by position and its role or
                  --  content is the term the engine has always had;
                  --  anything else indexed -- a list read out of a
                  --  tool's schema, a turn's calls, the pieces of a
                  --  cut, with whatever path follows -- is a name
                  --  indexed and read at render.
                  declare
                     Dot       : Natural := 0;
                     Tail_From : Natural := 1;
                     Tail_To   : Natural := 0;
                  begin
                     --  ns.field is one name, dot and all: the path,
                     --  if any, starts after it.
                     declare
                        Passed : Natural :=
                          (if Is_Namespace_Field (Word) then 1 else 0);
                     begin
                        for Position in Word'Range loop
                           if Word (Position) = '.' then
                              if Passed = 0 then
                                 Dot := Position;
                                 exit;
                              end if;
                              Passed := Passed - 1;
                           end if;
                        end loop;
                     end;

                     if After <= Text'Last and then Text (After) = '['
                     then
                        declare
                           Ends : Natural := After + 1;
                        begin
                           while Ends <= Text'Last
                             and then Text (Ends) /= ']'
                           loop
                              Ends := Ends + 1;
                           end loop;
                           if Ends > Text'Last then
                              return;
                           end if;

                           declare
                              Named : constant String :=
                                Model_Runner.Text.Trim
                                  (Text (After + 1 .. Ends - 1));
                           begin
                              if Named = "'role'"
                                or else Named = """role"""
                              then
                                 Field := 1;
                              elsif Named = "'content'"
                                or else Named = """content"""
                              then
                                 Field := 2;
                              elsif Named'Length > 2
                                and then Named (Named'First) in ''' | '"'
                              then
                                 Field := 3;
                                 Tail_From := After + 2;
                                 Tail_To := Ends - 2;
                              else
                                 --  A second position rather than a
                                 --  field: left for the index read
                                 --  after the term.
                                 Field := 3;
                                 Ends := After - 1;
                              end if;
                           end;
                           After := Ends + 1;
                        end;
                     elsif After + 4 <= Text'Last
                       and then Text (After .. After + 4) = ".role"
                       and then Dot = 0
                       and then (After + 5 > Text'Last
                                 or else Text (After + 5) not in
                                           'a' .. 'z' | '_')
                     then
                        Field := 1;
                        After := After + 5;
                     elsif After + 7 <= Text'Last
                       and then Text (After .. After + 7) = ".content"
                       and then Dot = 0
                       and then (After + 8 > Text'Last
                                 or else Text (After + 8) not in
                                           'a' .. 'z' | '_' | '.')
                     then
                        Field := 2;
                        After := After + 8;
                     elsif After <= Text'Last and then Text (After) = '.'
                     then
                        --  A path after the index, read to the end
                        --  of the dotted word -- less a method called
                        --  at its end, which is read after the term.
                        declare
                           Ends : Natural := After + 1;
                        begin
                           while Ends <= Text'Last
                             and then (Text (Ends) in 'a' .. 'z'
                                       | 'A' .. 'Z' | '0' .. '9'
                                       | '_' | '.')
                           loop
                              Ends := Ends + 1;
                           end loop;
                           if Ends <= Text'Last and then Text (Ends) = '('
                           then
                              for Named of Method_Names loop
                                 declare
                                    Len : constant Natural :=
                                      Named.Text.all'Length;
                                 begin
                                    if Ends - Len >= After
                                      and then Text (Ends - Len .. Ends - 1)
                                               = Named.Text.all
                                    then
                                       Ends := Ends - Len;
                                       exit;
                                    end if;
                                 end;
                              end loop;
                           end if;
                           Field := 3;
                           Tail_From := After + 1;
                           Tail_To := Ends - 1;
                           After := Ends;
                        end;
                     else
                        Field := 3;
                     end if;

                     Keep (Index, Kept);
                     if Kept = 0 then
                        return;
                     end if;

                     if Field in 1 | 2 and then Dot = 0 then
                        Result.Kind :=
                          (if Field = 1 then Term_Indexed_Role
                           else Term_Indexed_Content);

                        --  Which list, so that a template that
                        --  rebinds the name reads the rebound one,
                        --  and where the index was kept.
                        Result.Offset := 0;
                        Result.Index_At := Kept;
                        Result.Length := Slot_Of (Word);
                        if Result.Length = 0 then
                           Result := Refused (Word);
                        end if;
                     else
                        declare
                           Head   : constant String :=
                             (if Dot = 0 then Word
                              else Word (Word'First .. Dot - 1));
                           Stored : Boolean := True;
                        begin
                           Result.Kind := Term_Variable;
                           Result.Indexes := True;
                           Result.Index_At := Kept;
                           Result.Offset := Slot_Of (Head);
                           if Dot /= 0 then
                              Store_Literal
                                (Word (Dot + 1 .. Word'Last),
                                 Result.Path_At, Result.Path_Len,
                                 Stored);
                           end if;
                           if Stored and then Field = 1 then
                              Store_Literal
                                ("role", Result.Tail_At,
                                 Result.Tail_Len, Stored);
                           elsif Stored and then Field = 2 then
                              Store_Literal
                                ("content", Result.Tail_At,
                                 Result.Tail_Len, Stored);
                           elsif Stored and then Tail_To >= Tail_From
                           then
                              Store_Literal
                                (Text (Tail_From .. Tail_To),
                                 Result.Tail_At, Result.Tail_Len,
                                 Stored);
                           end if;
                           if not Stored or else Result.Offset = 0 then
                              Result := Refused (Word);
                           end if;
                        end;
                     end if;
                     From := After;
                     Ok := True;
                     return;
                  end;
               end;
            end;
         end if;

         <<Not_A_Position>>

         if Word = "strftime_now" then
            --  The function named without being called, which is how
            --  a template asks whether it is there: "strftime_now is
            --  defined". It is, and answers the empty string if
            --  printed as it stands.
            Result.Kind := Term_Now;
         elsif Word = "message.role" then
            Result.Kind := Term_Message_Role;
         elsif Word = "message.content" then
            Result.Kind := Term_Message_Content;
         elsif Word = "message.tool_calls" then
            --  Whether this turn asked for tools. It has no text --
            --  a list of calls is not something to print -- so a
            --  condition is the only place it answers.
            Result.Kind := Term_Message_Calls;
         elsif Word = "tool_call.name" then
            Result.Kind := Term_Call_Name;
         elsif Word = "tool_call.arguments" then
            Result.Kind := Term_Call_Arguments;
         elsif Word = "bos_token" and then not Is_Assigned (Word) then
            Result.Kind := Term_Beginning_Token;
         elsif Word = "eos_token" and then not Is_Assigned (Word) then
            --  The model's, unless the template set its own.
            Result.Kind := Term_End_Token;
         elsif Word = "add_generation_prompt" then
            Result.Kind := Term_Generation_Prompt;
         elsif Word = "loop.first" then
            Result.Kind := Term_Loop_First;
         elsif Word = "loop.last" then
            Result.Kind := Term_Loop_Last;
         elsif Word = "loop.length" then
            Result.Kind := Term_Loop_Length;
            Result.Numeric := True;
         elsif Word = "loop.revindex0" then
            Result.Kind := Term_Loop_Rev_Index_Zero;
            Result.Numeric := True;
         elsif Word = "loop.revindex" then
            Result.Kind := Term_Loop_Rev_Index_One;
            Result.Numeric := True;
         elsif Word = "loop.index0" then
            Result.Kind := Term_Loop_Index_Zero;
            Result.Numeric := True;
         elsif Word = "loop.index" then
            Result.Kind := Term_Loop_Index_One;
            Result.Numeric := True;
         elsif Word = "true" or else Word = "True" then
            Result.Kind := Term_True;
         elsif Word = "false" or else Word = "False" then
            Result.Kind := Term_False;
         elsif Word = "none" or else Word = "None" then
            Result.Kind := Term_None;
         elsif Word = "enable_thinking" then
            --  The one name a caller may answer that the template
            --  reads as a name of its own. Recorded so the render
            --  knows where to put the answer, and made a slot like any
            --  other so a template that assigns it still works.
            Result.Kind := Term_Variable;
            Result.Offset := Slot_Of (Word);
            if Result.Offset = 0 then
               Result := Refused (Word);
            else
               Item.Thinking_Slot := Result.Offset;
            end if;

         elsif Word = "loop.previtem" or else Word = "loop.nextitem"
           or else Model_Runner.Text.Starts_With (Word, "loop.previtem.")
           or else Model_Runner.Text.Starts_With (Word, "loop.nextitem.")
         then
            --  The message before or after the bound one, with
            --  whatever field is read off it.
            declare
               Stored : Boolean := True;
               Head_Length : constant := 13;
            begin
               Result.Kind :=
                 (if Word (Word'First + 5 .. Word'First + 8) = "prev"
                  then Term_Loop_Previous else Term_Loop_Next);
               if Word'Length > Head_Length then
                  Store_Literal
                    (Word (Word'First + Head_Length + 1 .. Word'Last),
                     Result.Path_At, Result.Path_Len, Stored);
               end if;
               if not Stored then
                  Result := Refused (Word);
               end if;
            end;
         elsif Is_Plain_Name (Word)
           or else Is_Namespace_Field (Word)
         then
            --  A name the template gives itself. Reading one it never
            --  assigned is an error at the point of reading, not here:
            --  'is defined' exists precisely to ask about names that
            --  were never assigned, and answering it is not the same as
            --  answering what they hold.
            Result.Kind := Term_Variable;
            Result.Offset := Slot_Of (Word);
            if Result.Offset = 0 then
               Result := Refused (Word);
            end if;
         elsif Ada.Strings.Fixed.Index (Word, ".") > Word'First
           and then Word (Word'Last) /= '.'
           and then Is_Plain_Name
                      (Word (Word'First
                             .. Ada.Strings.Fixed.Index (Word, ".") - 1))
         then
            --  A name and a path of members read off what it holds:
            --  a mapping's member, a message's field, a call's name
            --  or arguments. What the name holds is known when the
            --  render reads it, and so is whether it has the member.
            declare
               Dot    : constant Natural :=
                 Ada.Strings.Fixed.Index (Word, ".");
               Stored : Boolean;
            begin
               Result.Kind := Term_Variable;
               Result.Offset := Slot_Of (Word (Word'First .. Dot - 1));
               Store_Literal
                 (Word (Dot + 1 .. Word'Last), Result.Path_At,
                  Result.Path_Len, Stored);
               if Result.Offset = 0 or else not Stored then
                  Result := Refused (Word);
               end if;
            end;
         else
            --  A field of something, or a word this engine has never
            --  heard of. Either way it is a name that means nothing
            --  here, which is a different mistake from a construct.
            Result := Refused (Word, E.Template_Unknown_Variable);
         end if;

         Ok := True;
         Tail := 0;
         pragma Unreferenced (Tail);
      end;
   end;
end Read_Bare_Term;
