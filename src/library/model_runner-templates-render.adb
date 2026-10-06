separate (Model_Runner.Templates)
procedure Render
  (Item                  : Compiled;
   Messages              : Conv.History;
   Beginning_Token       : String;
   End_Token             : String;
   Add_Generation_Prompt : Boolean;
   Target                : out String;
   Last                  : out Natural;
   Status                : out E.Error_Info;
   Thinking              : Thinking_Choice := Thinking_Unstated;
   Tools                 : access constant Offered_Tools.Definitions
     := null;
   Image_Marker          : String := "";
   Video_Marker          : String := "")
is
   Count      : constant Natural := Conv.Length (Messages);

   --  How many tools the caller offered. None and none offered are the
   --  same thing to a template: "if tools" is false either way, and a
   --  model told about no tools is a model that was told nothing.
   Tool_Count : constant Natural :=
     (if Tools = null then 0 else Offered_Tools.Count (Tools.all));
   Position   : Natural := 1;
   Current    : Natural := 0;
   Loop_Start : Positive := 1;
   Loop_Stop  : Natural := Count;
   Iterations : Natural := 0;
   Overflow   : Boolean := False;

   --  What a name holds. A list is held as the position it starts at,
   --  because the only thing a template does to one is drop entries from
   --  the front of it.
   type Value_Kind is
     (Value_Undefined, Value_Text, Value_None, Value_List,

      --  True or false, which is what a comparison written as a value
      --  is worth, and what true and false are. Held as Start: one for
      --  true, and in a slot as Offset. Printed as Python prints it,
      --  and read in a condition as the truth it is.
      Value_Boolean,

      --  A whole number, held as its decimal text: what a number
      --  written down, a count, a length, a sum and a number read out
      --  of JSON are worth. Kept apart from text because the language
      --  keeps them apart -- 1 + 1 is 2 and '1' + '1' is '11', and 1
      --  is not equal to '1' -- and a name assigned a number stays one.
      Value_Number,

      --  A mapping or a list, as JSON text in the pool: what a member
      --  of a tool's schema, a call's arguments, a list written out or
      --  a cut into pieces is held as.
      Value_Data,

      --  One message of a list, held as its position. What a template
      --  binds when it walks the conversation by index rather than by
      --  loop, and what a loop binds too.
      Value_Message,

      --  The tools the caller offered, and one of them. Neither has any
      --  text: a template asks whether there are tools, walks them, and
      --  writes each one with tojson, and anything else it might do with
      --  one is refused rather than answered with a spelling this engine
      --  chose.
      Value_Tools,
      Value_JSON,

      --  One call of one turn, held as both positions: which message
      --  asked for it, and which of that message's calls it is. Both,
      --  because the loop that binds it runs inside the loop that binds
      --  the message and the inner binding must not depend on the outer
      --  one still being where it was.
      Value_Call);

   type Slot is record
      Kind   : Value_Kind := Value_Undefined;
      Offset : Natural := 0;
      Length : Natural := 0;
      --  Nought for a message's calls taken whole -- what
      --  {% set calls = message.tool_calls %} keeps -- and a position
      --  from one for everything else that has one.
      Start  : Natural := 1;
   end record;

   type Slot_Table is array (1 .. Max_Variables) of Slot;
   Slots : Slot_Table := [others => <>];

   --  Text the template has assigned to names. Sized against the output
   --  rather than fixed, because what goes in here is mostly message
   --  content on its way out.
   Pool_Size : constant Natural :=
     Natural'Min (Max_Variable_Bytes, Natural'Max (Target'Length, 1024));
   Pool      : String (1 .. Pool_Size) := [others => ' '];
   Pool_Used : Natural := 0;

   --  Set when the render reaches something the compiler carried through
   --  rather than answered. Reported like overflow, after the step.
   Refused     : Boolean := False;
   Refused_At  : Natural := 0;
   Refused_Len : Natural := 0;

   --  The bound a refusal names where it is a bound and not a
   --  construct: the elements a filter walks.
   Refused_Limit : Natural := 0;
   Refused_Why : E.Error_Code := E.Template_Unsupported_Construct;

   --  Refuse, naming a slice of the compiled source pool. The first
   --  refusal is the one reported: a condition can hold several terms and
   --  the reader wants the one that stopped it, not the last one looked at.
   procedure Refuse
     (Offset : Natural; Length : Natural; Why : E.Error_Code) is
   begin
      if not Refused then
         Refused := True;
         Refused_At := Offset;
         Refused_Len := Length;
         Refused_Why := Why;
      end if;
   end Refuse;

   --  Where each open capture began in the output, so that endset can
   --  take back what was written since.
   Captures      : array (1 .. Max_Depth) of Natural := [others => 0];
   Capture_Depth : Natural := 0;

   --  How many macro calls are in progress, and whether the innermost
   --  has reached its end; which body caller() runs at each depth, and
   --  the one named for the call about to be made.
   Call_Depth : Natural := 0;
   Returned   : Boolean := False;
   Callers    : array (0 .. Max_Depth) of Natural := [others => 0];
   Pending_Caller : Natural := 0;

   --  Whether the step limit has been reached, which the loop reports.
   Exhausted  : Boolean := False;

   --  Whether a break is on its way to the innermost loop's Next
   --  instruction, which leaves the loop instead of going round.
   Breaking   : Boolean := False;

   --  The with blocks in progress: what every name held when each
   --  began and where the pool stood, put back at its end.
   Scopes      : array (1 .. Max_Depth) of Slot_Table;
   Scope_Floor : array (1 .. Max_Depth) of Natural := [others => 0];
   Scope_Depth : Natural := 0;

   --  One instruction, at Position. Declared here because a macro call
   --  runs the body from inside the value that asks for it.
   procedure Execute;

   ------------------------------------------------------------------
   --  Values
   ------------------------------------------------------------------

   function Quoted (Value : String) return String;
   procedure Assign_Text
     (Where : Natural; Value : String; Kind : Value_Kind := Value_Text);
   function Number_Of (Text : String) return Long_Long_Integer;
   function Real_Of (Text : String) return Long_Float;
   function Real_Image (X : Long_Float) return String;
   function Rounded (X : Long_Float; Places : Natural) return Long_Float;
   function Fixed_Image (X : Long_Float; Places : Natural) return String;

   --  Whether a number's text is not a whole number: a point or an
   --  exponent in it. What decides whether a sum is worked out in
   --  whole numbers or in binary64.
   function Is_Real (Text : String) return Boolean
   is (for some C of Text => C in '.' | 'e' | 'E');

   --  Whether text is a number as written: digits, a sign, a point.
   function Is_Number_Text (Text : String) return Boolean
   is (Text'Length > 0
       and then Text (Text'First) in '0' .. '9' | '-' | '.'
       and then (for all C of Text =>
                   C in '0' .. '9' | '-' | '+' | '.' | 'e' | 'E'));

   --  What a term is worth before it is text: the value itself, with
   --  its kind. Text and a mapping or list -- JSON, as the tools and a
   --  call's arguments arrive and as a list written out or a cut made
   --  is spelled -- carry their text here; a message, a call and a tool
   --  carry their positions, as a slot does.
   type Held is record
      Kind  : Value_Kind := Value_Undefined;
      Text  : Ada.Strings.Unbounded.Unbounded_String;
      Start : Natural := 0;
      Index : Natural := 0;
      --  Whether a Value_Data is a message's content parts, which are
      --  rendered inline -- text and the picture markers -- where the
      --  value is wanted as text, rather than as their JSON.
      Parts : Boolean := False;
   end record;

   function Text_Of (Value : Held) return String
   is (Ada.Strings.Unbounded.To_String (Value.Text));

   --  Where a list of messages ends: Index, or a slot's Length, holds
   --  one past its last position where it was cut short --
   --  messages[:-1] -- and nought where it runs to the end.
   function Last_Of (Value : Held) return Natural
   is (if Value.Kind /= Value_List or else Value.Index = 0 then Count
       else Natural'Min (Value.Index - 1, Count));

   function Slot_Last (Holder : Slot) return Natural
   is (if Holder.Length = 0 then Count
       else Natural'Min (Holder.Length - 1, Count));

   --  A position in a list of messages from Start to Last, counted
   --  from zero, or from the end where it is negative; zero where the
   --  list does not reach it.
   function Message_At (Start, Last : Natural; Wanted : Long_Long_Integer)
     return Natural
   is (declare
         At_Message : constant Long_Long_Integer :=
           (if Wanted < 0 then Long_Long_Integer (Last) + 1 + Wanted
            else Long_Long_Integer (Start) + Wanted);
       begin
         (if At_Message < Long_Long_Integer (Start)
            or else At_Message > Long_Long_Integer (Last)
          then 0 else Natural (At_Message)));

   function As_Text (Value : String) return Held
   is (Kind => Value_Text,
       Text => Ada.Strings.Unbounded.To_Unbounded_String (Value),
       others => <>);

   function As_Data (Value : String) return Held
   is (Kind => Value_Data,
       Text => Ada.Strings.Unbounded.To_Unbounded_String (Value),
       others => <>);

   function As_Parts (Value : String) return Held
   is (Kind => Value_Data,
       Text => Ada.Strings.Unbounded.To_Unbounded_String (Value),
       Parts => True,
       others => <>);

   --  A number as its canonical text: a whole number as written, and
   --  one that is not written as Python writes it, so that 1.50 and
   --  1.0e15 print as 1.5 and 1000000000000000.0.
   function As_Number (Value : String) return Held
   is (Kind => Value_Number,
       Text => Ada.Strings.Unbounded.To_Unbounded_String
                 (if Is_Real (Value)
                  then Real_Image (Real_Of (Model_Runner.Text.Trim (Value)))
                  else Model_Runner.Text.Trim (Value)),
       others => <>);

   function As_Number (Value : Long_Long_Integer) return Held
   is (As_Number (Model_Runner.Text.Image (Value)));

   Nothing : constant Held := (Kind => Value_Undefined, others => <>);

   --  What a term is worth before its methods and filters, and after.
   --  Defined with the values' filters below, once the text they are
   --  built from is at hand.
   function Base_Of (Value : Term) return Held;
   function Indexed (Value : Held; Key : String) return Held;
   function Resolve (Value : Term) return Held;
   function Is_Sum (Value : Operand) return Boolean;
   function Has_Markup (Value : Operand) return Boolean;
   function Markup_Joined (Value : Operand) return String;
   function Is_Repetition (Value : Operand) return Boolean;
   function Held_Of (Value : Operand) return Held;
   function Truth_Of (Value : Condition) return Boolean;

   --  The JSON a value is, as text: a mapping or list as it stands, a
   --  tool as the definitions hold it, text as a JSON string, none as
   --  null.
   function Listed (Value : Held) return String;
   function Element_Of_Listed (One : Held) return String;

   function JSON_Text (Value : Held) return String is
   begin
      case Value.Kind is
         when Value_Data => return Text_Of (Value);
         when Value_JSON =>
            return Offered_Tools.Definition (Tools.all, Value.Start);
         when Value_Message => return Element_Of_Listed (Value);
         when Value_List | Value_Tools => return Listed (Value);
         when Value_Call =>
            if Value.Index = 0 then
               return Listed (Value);
            end if;
            if Value.Start = 0 or else Value.Start > Count
              or else Value.Index > Conv.Call_Count (Messages, Value.Start)
            then
               return "null";
            end if;
            return "{""type"": ""function"", ""function"": {""name"": "
              & Quoted (Conv.Call_Name (Messages, Value.Start, Value.Index))
              & ", ""arguments"": "
              & Conv.Call_Arguments (Messages, Value.Start, Value.Index)
              & "}}";
         when Value_Text => return Quoted (Text_Of (Value));
         when Value_Number => return Text_Of (Value);
         when Value_None => return "null";
         when Value_Boolean =>
            return (if Value.Start = 1 then "true" else "false");
         when others => return "";
      end case;
   end JSON_Text;

   --  Reading JSON, over whatever text holds it. A span of it, empty
   --  when First > Last.
   type Span is record
      First : Natural := 1;
      Last  : Natural := 0;
   end record;

   function Past_Blanks (Src : String; From : Natural) return Natural is
      I : Natural := From;
   begin
      while I <= Src'Last
        and then Src (I) in ' ' | ASCII.LF | ASCII.CR | ASCII.HT
      loop
         I := I + 1;
      end loop;
      return I;
   end Past_Blanks;

   --  The value beginning at From: a string with its quotes, an object
   --  or array with its brackets, or a bare number or word.
   function Value_At (Src : String; From : Natural) return Span is
      I : Natural := Past_Blanks (Src, From);
      Depth : Natural := 0;
      In_String : Boolean := False;
      Start : constant Natural := I;
   begin
      if I > Src'Last then
         return (1, 0);
      end if;
      if Src (I) = '"' then
         I := I + 1;
         while I <= Src'Last and then Src (I) /= '"' loop
            if Src (I) = '\' then
               I := I + 1;
            end if;
            I := I + 1;
         end loop;
         return (Start, Natural'Min (I, Src'Last));
      elsif Src (I) in '{' | '[' then
         loop
            exit when I > Src'Last;
            if In_String then
               if Src (I) = '\' then
                  I := I + 1;
               elsif Src (I) = '"' then
                  In_String := False;
               end if;
            elsif Src (I) = '"' then
               In_String := True;
            elsif Src (I) in '{' | '[' then
               Depth := Depth + 1;
            elsif Src (I) in '}' | ']' then
               Depth := Depth - 1;
               exit when Depth = 0;
            end if;
            I := I + 1;
         end loop;
         return (Start, Natural'Min (I, Src'Last));
      else
         while I <= Src'Last
           and then Src (I) not in ',' | '}' | ']' | ' ' | ASCII.LF
         loop
            I := I + 1;
         end loop;
         return (Start, I - 1);
      end if;
   end Value_At;

   --  The next member of an object from Cursor, which starts just past
   --  the opening brace; Found is False at the closing one.
   procedure Next_Member
     (Src    : String;
      Cursor : in out Natural;
      Key    : out Span;
      Value  : out Span;
      Found  : out Boolean)
   is
      I : Natural := Past_Blanks (Src, Cursor);
   begin
      Found := False;
      Key := (1, 0);
      Value := (1, 0);
      if I <= Src'Last and then Src (I) = ',' then
         I := Past_Blanks (Src, I + 1);
      end if;
      if I > Src'Last or else Src (I) /= '"' then
         return;
      end if;
      Key := Value_At (Src, I);
      I := Past_Blanks (Src, Key.Last + 1);
      if I <= Src'Last and then Src (I) = ':' then
         I := I + 1;
      end if;
      Value := Value_At (Src, I);
      Cursor := Value.Last + 1;
      Found := True;
   end Next_Member;

   --  The next element of an array from Cursor, just past the bracket.
   procedure Next_Element
     (Src    : String;
      Cursor : in out Natural;
      Value  : out Span;
      Found  : out Boolean)
   is
      I : Natural := Past_Blanks (Src, Cursor);
   begin
      Found := False;
      Value := (1, 0);
      if I <= Src'Last and then Src (I) = ',' then
         I := Past_Blanks (Src, I + 1);
      end if;
      if I > Src'Last or else Src (I) = ']' then
         return;
      end if;
      Value := Value_At (Src, I);
      Cursor := Value.Last + 1;
      Found := True;
   end Next_Element;

   function Is_JSON_String (Src : String) return Boolean
   is (Src'Length > 0 and then Src (Src'First) = '"');
   function Is_JSON_Mapping (Src : String) return Boolean
   is (Src'Length > 0 and then Src (Src'First) = '{');
   function Is_JSON_List (Src : String) return Boolean
   is (Src'Length > 0 and then Src (Src'First) = '[');

   --  A tuple -- written ('a', 1), or a pair dictsort and items make --
   --  is held as a list whose bracket a blank follows: JSON that came
   --  in is held without one, and every list this engine writes opens
   --  with the bracket alone. It prints as Python prints a tuple, and
   --  tojson writes it as the list JSON makes of one.
   Tuple_Open : constant String := "[ ";

   function Is_Tuple (Src : String) return Boolean
   is (Src'Length > 1 and then Src (Src'First .. Src'First + 1) = Tuple_Open);

   --  JSON text with the blank that marks a tuple taken out, outside
   --  strings.
   function Untupled (Src : String) return String is
      R     : String (1 .. Src'Length);
      M     : Natural := 0;
      Quote : Boolean := False;
      I     : Natural := Src'First;
   begin
      while I <= Src'Last loop
         M := M + 1;
         R (M) := Src (I);
         if Quote then
            if Src (I) = '\' and then I < Src'Last then
               M := M + 1;
               R (M) := Src (I + 1);
               I := I + 1;
            elsif Src (I) = '"' then
               Quote := False;
            end if;
         elsif Src (I) = '"' then
            Quote := True;
         elsif Src (I) = '[' and then I < Src'Last
           and then Src (I + 1) = ' '
         then
            I := I + 1;
         end if;
         I := I + 1;
      end loop;
      return R (1 .. M);
   end Untupled;

   --  A JSON string's characters. The escapes are the ones JSON
   --  requires; a definition's own are decoded already.
   function Decoded (Src : String) return String is
      R : String (1 .. Src'Length);
      M : Natural := 0;
      I : Natural := Src'First + 1;
   begin
      if not Is_JSON_String (Src) then
         return Src;
      end if;
      while I < Src'Last loop
         if Src (I) = '\' and then I + 1 < Src'Last then
            I := I + 1;
            M := M + 1;
            case Src (I) is
               when 'n' => R (M) := ASCII.LF;
               when 't' => R (M) := ASCII.HT;
               when 'r' => R (M) := ASCII.CR;
               when others => R (M) := Src (I);
            end case;
         else
            M := M + 1;
            R (M) := Src (I);
         end if;
         I := I + 1;
      end loop;
      return R (1 .. M);
   end Decoded;

   --  A member of a mapping by name, or nothing.
   --  A value read out of JSON: a string is text, decoded, so that
   --  what is done to it -- indexed, measured, asked whether it begins
   --  with something -- is done to the text; anything else stays
   --  JSON.
   --  A JSON number, whole or not: digits with a sign, a point and an
   --  exponent where it has them.
   function Is_JSON_Number (Src : String) return Boolean
   is (Src'Length > 0
       and then Src (Src'First) in '0' .. '9' | '-'
       and then Src (Src'Last) in '0' .. '9'
       and then (for all C of Src =>
                   C in '0' .. '9' | '-' | '+' | '.' | 'e' | 'E'));

   function Read_Out (Src : String) return Held
   is (if Is_JSON_String (Src) then As_Text (Decoded (Src))
       elsif Is_JSON_Number (Src) then As_Number (Src)
       elsif Src = "null" then (Kind => Value_None, others => <>)
       elsif Src = "true" then (Kind => Value_Boolean, Start => 1, others => <>)
       elsif Src = "false" then (Kind => Value_Boolean, Start => 0, others => <>)
       else As_Data (Src));

   function Member_Of (Src : String; Name : String) return Held is
      Cursor : Natural;
      Key, Value : Span;
      Found : Boolean;
   begin
      if not Is_JSON_Mapping (Src) then
         return Nothing;
      end if;
      Cursor := Src'First + 1;
      loop
         Next_Member (Src, Cursor, Key, Value, Found);
         exit when not Found;
         if Decoded (Src (Key.First .. Key.Last)) = Name then
            return Read_Out (Src (Value.First .. Value.Last));
         end if;
      end loop;
      return Nothing;
   end Member_Of;

   --  An element of a list by position, counted from zero and from the
   --  end where negative, or nothing.
   function Element_Of (Src : String; Wanted : Long_Long_Integer)
     return Held
   is
      Cursor : Natural;
      Value  : Span;
      Found  : Boolean;
      Total  : Natural := 0;
      Seen   : Long_Long_Integer := 0;
      Target_Index : Long_Long_Integer := Wanted;
   begin
      if not Is_JSON_List (Src) then
         return Nothing;
      end if;
      if Wanted < 0 then
         Cursor := Src'First + 1;
         loop
            Next_Element (Src, Cursor, Value, Found);
            exit when not Found;
            Total := Total + 1;
         end loop;
         Target_Index := Long_Long_Integer (Total) + Wanted;
         if Target_Index < 0 then
            return Nothing;
         end if;
      end if;
      Cursor := Src'First + 1;
      loop
         Next_Element (Src, Cursor, Value, Found);
         exit when not Found;
         if Seen = Target_Index then
            return Read_Out (Src (Value.First .. Value.Last));
         end if;
         Seen := Seen + 1;
      end loop;
      return Nothing;
   end Element_Of;

   --  How many elements a list has, or entries a mapping.
   function JSON_Length (Src : String) return Natural is
      Cursor : Natural;
      Key, Value : Span;
      Found : Boolean;
      Total : Natural := 0;
   begin
      if Is_JSON_List (Src) then
         Cursor := Src'First + 1;
         loop
            Next_Element (Src, Cursor, Value, Found);
            exit when not Found;
            Total := Total + 1;
         end loop;
      elsif Is_JSON_Mapping (Src) then
         Cursor := Src'First + 1;
         loop
            Next_Member (Src, Cursor, Key, Value, Found);
            exit when not Found;
            Total := Total + 1;
         end loop;
      elsif Is_JSON_String (Src) then
         return Decoded (Src)'Length;
      end if;
      return Total;
   end JSON_Length;

   --  Python's str of a JSON value, which is what `| string` and a
   --  printed value are: a string as its characters, true as True,
   --  null as None, and a list or a mapping as its repr, strings in
   --  single quotes.
   function Pythonic (Src : String) return String;

   function Repr (Src : String) return String is
      R : Ada.Strings.Unbounded.Unbounded_String;
      Cursor : Natural;
      Key, Value : Span;
      Found : Boolean;
      First_One : Boolean := True;
   begin
      if Is_JSON_String (Src) then
         return "'" & Decoded (Src) & "'";
      elsif Is_JSON_List (Src) then
         declare
            Tuple : constant Boolean := Is_Tuple (Src);
            Many  : Natural := 0;
         begin
            Ada.Strings.Unbounded.Append (R, (if Tuple then "(" else "["));
            Cursor := Src'First + 1;
            loop
               Next_Element (Src, Cursor, Value, Found);
               exit when not Found;
               if not First_One then
                  Ada.Strings.Unbounded.Append (R, ", ");
               end if;
               First_One := False;
               Many := Many + 1;
               Ada.Strings.Unbounded.Append
                 (R, Repr (Src (Value.First .. Value.Last)));
            end loop;
            --  Python writes a tuple of one with its comma: (1,).
            Ada.Strings.Unbounded.Append
              (R, (if not Tuple then "]" elsif Many = 1 then ",)"
                   else ")"));
         end;
         return Ada.Strings.Unbounded.To_String (R);
      elsif Is_JSON_Mapping (Src) then
         Ada.Strings.Unbounded.Append (R, "{");
         Cursor := Src'First + 1;
         loop
            Next_Member (Src, Cursor, Key, Value, Found);
            exit when not Found;
            if not First_One then
               Ada.Strings.Unbounded.Append (R, ", ");
            end if;
            First_One := False;
            Ada.Strings.Unbounded.Append
              (R, Repr (Src (Key.First .. Key.Last)) & ": "
                  & Repr (Src (Value.First .. Value.Last)));
         end loop;
         Ada.Strings.Unbounded.Append (R, "}");
         return Ada.Strings.Unbounded.To_String (R);
      end if;
      return Pythonic (Src);
   end Repr;

   function Pythonic (Src : String) return String is
   begin
      if Is_JSON_String (Src) then
         return Decoded (Src);
      elsif Is_JSON_List (Src) or else Is_JSON_Mapping (Src) then
         return Repr (Src);
      elsif Src = "true" then
         return "True";
      elsif Src = "false" then
         return "False";
      elsif Src = "null" then
         return "None";
      end if;
      return Src;
   end Pythonic;

   --  What a value prints as.
   function Printed (Value : Held) return String is
   begin
      case Value.Kind is
         when Value_Text | Value_Number => return Text_Of (Value);
         when Value_Data => return Pythonic (Text_Of (Value));
         --  A tool's definition, or the tools, printed as the language
         --  prints a mapping or a list -- {'type': 'function', ...} --
         --  where a template writes {{ tool }} rather than | tojson.
         when Value_JSON => return Pythonic (JSON_Text (Value));
         when Value_Tools => return Pythonic (Listed (Value));
         when Value_Boolean =>
            return (if Value.Start = 1 then "True" else "False");
         when Value_None => return "None";
         when others => return "";
      end case;
   end Printed;

   --  A slot's value.
   function Held_Of (Where : Natural) return Held is
      Holder : Slot renames Slots (Where);
   begin
      case Holder.Kind is
         when Value_Text =>
            return As_Text
              (Pool (Holder.Offset + 1 .. Holder.Offset + Holder.Length));
         when Value_Number =>
            return As_Number
              (Pool (Holder.Offset + 1 .. Holder.Offset + Holder.Length));
         when Value_Data =>
            return As_Data
              (Pool (Holder.Offset + 1 .. Holder.Offset + Holder.Length));
         when Value_Message =>
            return (Kind => Value_Message, Start => Holder.Start,
                    others => <>);
         when Value_Call =>
            return (Kind => Value_Call, Start => Holder.Offset,
                    Index => Holder.Start, others => <>);
         when Value_JSON =>
            return (Kind => Value_JSON, Start => Holder.Start,
                    others => <>);
         when Value_List =>
            return (Kind => Value_List, Start => Holder.Start,
                    Index => Holder.Length, others => <>);
         when Value_Tools =>
            return (Kind => Value_Tools, others => <>);
         when Value_None =>
            return (Kind => Value_None, others => <>);
         when Value_Boolean =>
            return (Kind => Value_Boolean, Start => Holder.Offset,
                    others => <>);
         when Value_Undefined =>
            return Nothing;
      end case;
   end Held_Of;

   --  A message's content: its text, or the list of parts it was given
   --  instead, which a template walks -- "content is string" is the
   --  question every one of them asks first.
   function Content_Of (At_Message : Natural) return Held is
   begin
      if At_Message = 0 or else At_Message > Count then
         return Nothing;
      end if;
      declare
         Parts : constant String := Conv.Parts_At (Messages, At_Message);
      begin
         if Parts'Length > 0 then
            return As_Parts (Parts);
         end if;
         return As_Text (Conv.Content_At (Messages, At_Message));
      end;
   end Content_Of;

   --  A message's field, a call's, a tool's or a mapping's member, by
   --  name. A field a message has not got is nothing, which is what a
   --  template's "is defined" is written to find out.
   function Field_Of (Value : Held; Name : String) return Held is
   begin
      case Value.Kind is
         when Value_Message =>
            if Value.Start = 0 or else Value.Start > Count then
               return Nothing;
            elsif Name = "role" then
               return As_Text
                 (Conv.Role_Name (Conv.Sender_At (Messages, Value.Start)));
            elsif Name = "content" then
               return Content_Of (Value.Start);
            elsif Name = "tool_calls" then
               if Conv.Call_Count (Messages, Value.Start) = 0 then
                  return Nothing;
               end if;
               return (Kind => Value_Call, Start => Value.Start,
                       Index => 0, others => <>);
            end if;
            return Nothing;

         when Value_Call =>
            if Value.Index = 0 then
               return Nothing;
            elsif Name = "name" then
               return As_Text
                 (Conv.Call_Name (Messages, Value.Start, Value.Index));
            elsif Name = "arguments" then
               return As_Data
                 (Conv.Call_Arguments (Messages, Value.Start, Value.Index));
            elsif Name = "function" then
               --  A call as the conversation's JSON writes it:
               --  {"type": "function", "function": {"name", "arguments"}}.
               --  Templates read the name either way, call.name or
               --  call.function.name, and some take call.get("function")
               --  first and read the rest off what that gave.
               return Value;
            elsif Name = "type" then
               return As_Text ("function");
            end if;
            return Nothing;

         when Value_JSON | Value_Data =>
            return Member_Of (JSON_Text (Value), Name);

         when others =>
            return Nothing;
      end case;
   end Field_Of;

   subtype Structured is Value_Kind
     with Static_Predicate => Structured in Value_Data | Value_JSON
       | Value_Message | Value_List | Value_Tools | Value_Call;

   --  A path of members read off a value, one name at a time.
   function Along (Value : Held; Path : String) return Held is
      Result : Held := Value;
      From   : Natural := Path'First;
   begin
      while From <= Path'Last loop
         declare
            Dot : Natural := From;
         begin
            while Dot <= Path'Last and then Path (Dot) /= '.' loop
               Dot := Dot + 1;
            end loop;
            Result := Field_Of (Result, Path (From .. Dot - 1));
            From := Dot + 1;
         end;
      end loop;
      return Result;
   end Along;

   --  An element of a value by position: of a list, of a turn's calls,
   --  of a list of messages.
   function Element_At (Value : Held; Wanted : Long_Long_Integer)
     return Held is
   begin
      case Value.Kind is
         when Value_Data =>
            return Element_Of (Text_Of (Value), Wanted);
         when Value_Text =>
            --  One character of the text, counted from the end when
            --  the position is negative; a position past either end
            --  is nothing, where the language would raise.
            declare
               Held : constant String := Text_Of (Value);
               At_Char : constant Long_Long_Integer :=
                 (if Wanted < 0
                  then Long_Long_Integer (Held'Length) + Wanted
                  else Wanted);
            begin
               if At_Char < 0
                 or else At_Char >= Long_Long_Integer (Held'Length)
               then
                  return Nothing;
               end if;
               return As_Text
                 (Held (Held'First + Natural (At_Char)
                        .. Held'First + Natural (At_Char)));
            end;
         when Value_Call =>
            --  The calls of a turn, indexed: Index zero says the whole
            --  list is meant.
            declare
               Total : constant Natural :=
                 (if Value.Start = 0 or else Value.Start > Count then 0
                  else Conv.Call_Count (Messages, Value.Start));
               At_Call : constant Long_Long_Integer :=
                 (if Wanted < 0 then Long_Long_Integer (Total) + Wanted + 1
                  else Wanted + 1);
            begin
               if Value.Index /= 0 or else At_Call < 1
                 or else At_Call > Long_Long_Integer (Total)
               then
                  return Nothing;
               end if;
               return (Kind => Value_Call, Start => Value.Start,
                       Index => Natural (At_Call), others => <>);
            end;
         when Value_List =>
            declare
               At_Message : constant Natural :=
                 Message_At (Value.Start, Last_Of (Value), Wanted);
            begin
               if At_Message = 0 then
                  return (Kind => Value_None, others => <>);
               end if;
               return (Kind => Value_Message, Start => At_Message,
                       others => <>);
            end;
         when Value_Tools =>
            if Wanted < 0 or else Wanted >= Long_Long_Integer (Tool_Count)
            then
               return Nothing;
            end if;
            return (Kind => Value_JSON, Start => Natural (Wanted) + 1,
                    others => <>);
         when others =>
            return Nothing;
      end case;
   end Element_At;

   --  A structured value as JSON: a message as the object the
   --  conversation's JSON writes, anything else as the lists walk it.
   function Structure_Of (Value : Held) return String is
   begin
      if Value.Kind = Value_Message then
         return JSON_Text
           (Element_At
              (As_Data (Listed ((Kind => Value_List, Start => Value.Start,
                                 others => <>))), 0));
      elsif Value.Kind = Value_Call and then Value.Index /= 0 then
         return JSON_Text
           (Element_At
              (As_Data (Listed ((Kind => Value_Call, Start => Value.Start,
                                 Index => 0, others => <>))),
               Long_Long_Integer (Value.Index) - 1));
      end if;
      return Listed (Value);
   end Structure_Of;

   --  How many things a value holds: a text's characters, a list's
   --  elements, a mapping's entries, the tools, the messages of a list
   --  from where it begins, a turn's calls.
   function Length_Of (Value : Held) return Natural is
   begin
      case Value.Kind is
         when Value_Text => return Text_Of (Value)'Length;
         when Value_Data => return JSON_Length (Text_Of (Value));
         when Value_JSON => return JSON_Length (JSON_Text (Value));
         when Value_Tools => return Tool_Count;
         when Value_List =>
            return Integer'Max (Last_Of (Value) - Value.Start + 1, 0);
         when Value_Call =>
            if Value.Index /= 0 or else Value.Start = 0
              or else Value.Start > Count
            then
               return 0;
            end if;
            return Conv.Call_Count (Messages, Value.Start);
         when others => return 0;
      end case;
   end Length_Of;

   --  Whether a value holds anything, as a condition asks.
   function Is_Truthy (Value : Held) return Boolean is
   begin
      case Value.Kind is
         when Value_Undefined | Value_None => return False;
         when Value_Boolean => return Value.Start = 1;
         when Value_Number => return Number_Of (Text_Of (Value)) /= 0;
         when Value_Text =>
            declare
               T : constant String := Text_Of (Value);
            begin
               return T /= "" and then T /= "false" and then T /= "none"
                 and then T /= "0";
            end;
         when Value_Data =>
            declare
               T : constant String := Text_Of (Value);
            begin
               return T /= "[]" and then T /= "[ ]" and then T /= "{}"
                 and then T /= "false"
                 and then T /= "null" and then T /= "0"
                 and then T /= """""";
            end;
         when Value_Tools => return Tool_Count > 0;
         when Value_List => return Last_Of (Value) >= Value.Start;
         when Value_Call => return Length_Of (Value) > 0 or else Value.Index > 0;
         when others => return True;
      end case;
   end Is_Truthy;

   --  Give a name a value, keeping its kind: text and JSON into the
   --  pool, positions as they are.
   procedure Assign_Data (Where : Natural; Value : String);

   procedure Store (Where : Natural; Value : Held) is
   begin
      case Value.Kind is
         when Value_Text => Assign_Text (Where, Text_Of (Value));
         when Value_Number =>
            Assign_Text (Where, Text_Of (Value), Value_Number);
         when Value_Data => Assign_Data (Where, Text_Of (Value));
         when Value_Message =>
            Slots (Where) := (Kind => Value_Message, Offset => 0,
                              Length => 0, Start => Value.Start);
         when Value_Call =>
            Slots (Where) := (Kind => Value_Call, Offset => Value.Start,
                              Length => 0, Start => Value.Index);
         when Value_JSON =>
            Slots (Where) := (Kind => Value_JSON, Start => Value.Start,
                              others => <>);
         when Value_List =>
            Slots (Where) := (Kind => Value_List, Start => Value.Start,
                              Length => Value.Index, others => <>);
         when Value_Tools =>
            Slots (Where) := (Kind => Value_Tools, others => <>);
         when Value_None =>
            Slots (Where) := (Kind => Value_None, others => <>);
         when Value_Boolean =>
            Slots (Where) := (Kind => Value_Boolean, Offset => Value.Start,
                              others => <>);
         when Value_Undefined =>
            Slots (Where) := (Kind => Value_Undefined, others => <>);
      end case;
   end Store;

   --  Grow the list or mapping a name holds in place: an element
   --  appended, a list's elements appended, or a mapping's members
   --  added -- {% do name.append(v) %} and its two siblings. A name
   --  holding nothing grows from empty.
   procedure Grow (Where : Natural; Value : Operand; How : Natural) is
      Current : constant Held := Held_Of (Where);
      Added   : constant Held := Held_Of (Value);
      Src     : constant String :=
        (if Current.Kind = Value_Data then Text_Of (Current)
         elsif Current.Kind in Value_Tools | Value_List | Value_Call
         then Listed (Current)
         elsif How = 3 then "{}" else "[]");
      R       : Ada.Strings.Unbounded.Unbounded_String;

      --  The added value as JSON, a list's elements one by one.
      function Added_JSON return String
      is (if Added.Kind = Value_Undefined then "null"
          elsif Added.Kind in Value_Tools | Value_List | Value_Call
          then Listed (Added)
          elsif Added.Kind = Value_Message then Element_Of_Listed (Added)
          else JSON_Text (Added));
   begin
      if Where = 0 then
         return;
      end if;
      case How is
         when 1 | 2 =>
            if not Is_JSON_List (Src) then
               return;
            end if;
            declare
               Inner : constant String :=
                 Model_Runner.Text.Trim (Src (Src'First + 1 .. Src'Last - 1));
               More  : constant String :=
                 (if How = 1 then Added_JSON
                  else Model_Runner.Text.Trim
                         (Added_JSON (Added_JSON'First + 1
                                      .. Added_JSON'Last - 1)));
            begin
               if How = 2 and then not Is_JSON_List (Added_JSON) then
                  return;
               end if;
               Ada.Strings.Unbounded.Append (R, "[" & Inner);
               if Inner'Length > 0 and then More'Length > 0 then
                  Ada.Strings.Unbounded.Append (R, ", ");
               end if;
               Ada.Strings.Unbounded.Append (R, More & "]");
            end;
         when others =>
            if not Is_JSON_Mapping (Src) or else not Is_JSON_Mapping (Added_JSON)
            then
               return;
            end if;
            declare
               Inner : constant String :=
                 Model_Runner.Text.Trim (Src (Src'First + 1 .. Src'Last - 1));
               More  : constant String :=
                 Model_Runner.Text.Trim
                   (Added_JSON (Added_JSON'First + 1 .. Added_JSON'Last - 1));
            begin
               Ada.Strings.Unbounded.Append (R, "{" & Inner);
               if Inner'Length > 0 and then More'Length > 0 then
                  Ada.Strings.Unbounded.Append (R, ", ");
               end if;
               Ada.Strings.Unbounded.Append (R, More & "}");
            end;
      end case;
      Assign_Data (Where, Ada.Strings.Unbounded.To_String (R));
   end Grow;

   ------------------------------------------------------------------
   --  Loops, of every kind, on one stack
   ------------------------------------------------------------------

   --  What a running loop walks and where it has got to, so that
   --  loop.first and its kin answer for the innermost loop whatever
   --  kind it is, and so that loops nest -- one over a mapping's
   --  entries inside one over a list inside one over the tools, which
   --  is what a template that writes a schema out does. The legacy
   --  kinds keep their state where they always did and are here only
   --  so that the stack knows which loop is innermost.
   type Loop_Kind is
     (Over_Elements,   --  a JSON list, element by element
      Over_Entries,    --  a JSON mapping, entry by entry
      Over_Tools,      --  the tools offered
      Over_Messages,   --  a list of messages
      Over_Calls,      --  a turn's calls
      Legacy_List, Legacy_Calls, Legacy_Range,

      --  Not a loop: a macro call, on the same stack because it scopes
      --  names the same way -- what the body assigns is the body's own
      --  and is put back when it returns, a namespace's field aside --
      --  and so that loop.index inside a macro is not the caller's.
      Macro_Call);

   type Fresh_Set is array (1 .. Max_Variables) of Boolean;

   type Loop_State is record
      Kind    : Loop_Kind := Legacy_List;
      Var     : Natural := 0;   --  the slot each element goes to
      Key     : Natural := 0;   --  and the entry's key, for a mapping
      Base    : Natural := 0;   --  the container's text in the pool
      Base_Length : Natural := 0;
      Cursor  : Natural := 0;   --  where the next element is read from
      Index   : Natural := 0;   --  one for the first element
      Total   : Natural := 0;
      Message : Natural := 0;   --  the turn a calls loop walks
      From, To : Natural := 0;  --  a message list's ends
      Reversed : Boolean := False;

      --  What every name held when the loop began, and how much of the
      --  pool was in use. A name assigned inside a loop's body is the
      --  body's own -- the language scopes it so, and a template that
      --  builds a value in a loop and reads it after is reading what
      --  the name held before -- so the names are put back when the
      --  loop ends. A namespace's field is the one thing that outlives
      --  the loop, which is what namespaces are for.
      Saved : Slot_Table := [others => <>];
      Floor : Natural := 0;

      --  The namespaces made inside the body, by the slot of their name.
      Fresh : Fresh_Set := [others => False];
      Any_Fresh : Boolean := False;
   end record;

   Max_Loops : constant := 4 * Max_Depth;
   Loops     : array (1 .. Max_Loops) of Loop_State;
   Loop_Depth : Natural := 0;

   procedure Push_Loop (State : Loop_State) is
   begin
      if Loop_Depth < Max_Loops then
         Loop_Depth := Loop_Depth + 1;
         Loops (Loop_Depth) := State;
         Loops (Loop_Depth).Saved := Slots;
         Loops (Loop_Depth).Floor := Pool_Used;
      end if;
   end Push_Loop;

   --  The pool below the innermost loop's floor is what names held
   --  before it began, and is kept as it was until the loop ends.
   function Floor_Now return Natural
   is (Natural'Max
         ((if Loop_Depth > 0 then Loops (Loop_Depth).Floor else 0),
          (if Scope_Depth > 0 then Scope_Floor (Scope_Depth) else 0)));

   --  Whether a name is a namespace's field, which is spelled with a
   --  dot and is the one kind of name a loop's body assigns for after.
   function Is_Namespace_Slot (Where : Positive) return Boolean
   is (for some Letter of
         Item.Source.all (Item.Names (Where).Offset + 1
                          .. Item.Names (Where).Offset
                             + Item.Names (Where).Length)
       => Letter = '.');

   --  Put every name back to what it held when a body began -- a
   --  namespace's field aside -- and give the pool back to where it
   --  stood, unless something that outlives the body was put there.
   procedure Restore_Names (Saved : Slot_Table; Floor : Natural) is
      Kept_Above : Boolean := False;
   begin
      for Index in 1 .. Item.Name_Used loop
         if not Is_Namespace_Slot (Index) then
            Slots (Index) := Saved (Index);
         end if;
         if Slots (Index).Kind in Value_Text | Value_Data | Value_Number
           and then Slots (Index).Offset + Slots (Index).Length > Floor
         then
            Kept_Above := True;
         end if;
      end loop;
      if not Kept_Above and then Pool_Used > Floor then
         Pool_Used := Floor;
      end if;
   end Restore_Names;

   procedure Pop_Loop is
   begin
      if Loop_Depth = 0 then
         return;
      end if;
      Restore_Names (Loops (Loop_Depth).Saved, Loops (Loop_Depth).Floor);

      --  The fields of a namespace the body made are the body's own:
      --  a macro's ns hides the template's ns while it runs, no longer.
      if Loops (Loop_Depth).Any_Fresh then
         for Index in 1 .. Item.Name_Used loop
            if Is_Namespace_Slot (Index) then
               declare
                  Name : constant String :=
                    Item.Source.all (Item.Names (Index).Offset + 1
                                     .. Item.Names (Index).Offset
                                        + Item.Names (Index).Length);
                  Dot  : Natural := Name'First;
               begin
                  while Name (Dot) /= '.' loop
                     Dot := Dot + 1;
                  end loop;
                  for Head in 1 .. Item.Name_Used loop
                     if Loops (Loop_Depth).Fresh (Head)
                       and then Item.Source.all
                                  (Item.Names (Head).Offset + 1
                                   .. Item.Names (Head).Offset
                                      + Item.Names (Head).Length)
                                = Name (Name'First .. Dot - 1)
                     then
                        Slots (Index) := Loops (Loop_Depth).Saved (Index);
                     end if;
                  end loop;
               end;
            end if;
         end loop;
      end if;
      Loop_Depth := Loop_Depth - 1;
   end Pop_Loop;

   --  Whether the innermost loop is one of the new kinds, whose state
   --  is on the stack rather than in the legacy variables.
   function Innermost_Is_New return Boolean
   is (Loop_Depth > 0
       and then Loops (Loop_Depth).Kind in Over_Elements .. Over_Calls);

   --  Give a name a text value, taking back the room the name last held
   --  where that room is the newest in the pool. Written once because
   --  three instructions do it and one of them does it every time round
   --  a loop.
   procedure Assign_Text
     (Where : Natural; Value : String; Kind : Value_Kind := Value_Text)
   is
      Held : Slot renames Slots (Where);
   begin
      --  A name reassigned in a loop -- which is how a template builds
      --  one message's text before emitting it -- is almost always the
      --  newest thing in the pool. Taking its room back makes that loop
      --  cost what one iteration costs instead of what all of them do.
      --  Value is already a copy, so the old text may go.
      if Held.Kind in Value_Text | Value_Data | Value_Number
        and then Held.Offset + Held.Length = Pool_Used
        and then Held.Offset >= Floor_Now
      then
         Pool_Used := Held.Offset;
      end if;

      if Pool_Used + Value'Length > Pool'Length then
         Refuse (Item.Names (Where).Offset, Item.Names (Where).Length,
                 E.Template_Variables_Too_Large);
      else
         Pool (Pool_Used + 1 .. Pool_Used + Value'Length) := Value;
         Slots (Where) :=
           (Kind => Kind, Offset => Pool_Used,
            Length => Value'Length, Start => 1);
         Pool_Used := Pool_Used + Value'Length;
      end if;
   end Assign_Text;

   --  The same for a mapping or a list, which lives in the pool as its
   --  JSON and is told from text by its kind.
   procedure Assign_Data (Where : Natural; Value : String) is
      Held : Slot renames Slots (Where);
   begin
      if Held.Kind in Value_Text | Value_Data | Value_Number
        and then Held.Offset + Held.Length = Pool_Used
        and then Held.Offset >= Floor_Now
      then
         Pool_Used := Held.Offset;
      end if;

      if Pool_Used + Value'Length > Pool'Length then
         Refuse (Item.Names (Where).Offset, Item.Names (Where).Length,
                 E.Template_Variables_Too_Large);
      else
         Pool (Pool_Used + 1 .. Pool_Used + Value'Length) := Value;
         Slots (Where) :=
           (Kind => Value_Data, Offset => Pool_Used,
            Length => Value'Length, Start => 1);
         Pool_Used := Pool_Used + Value'Length;
      end if;
   end Assign_Data;

   --  Bind the name a message goes by to one position, or to nothing.
   --  A loop binds it as it goes, which is what makes message.role inside
   --  a loop and message.role after an assignment the same question.
   procedure Bind_Message (At_Message : Natural) is
   begin
      if Item.Message_Slot = 0 then
         return;
      elsif At_Message = 0 then
         Slots (Item.Message_Slot) := (Kind => Value_Undefined,
                                       others => <>);
      else
         Slots (Item.Message_Slot) :=
           (Kind => Value_Message, Offset => 0, Length => 0,
            Start => At_Message);
      end if;
   end Bind_Message;

   --  Which message the name message stands for. A loop binds it, and
   --  so does an assignment; the binding in force is whatever the name
   --  holds, and the loop's own position is what it holds while a loop
   --  is running.
   function Bound_Message return Natural is
      Held : Slot renames Slots (Item.Message_Slot);
   begin
      return (if Held.Kind = Value_Message then Held.Start else Current);
   end Bound_Message;

   --  Whether the name message holds a message written out as a
   --  mapping, which a loop over a slice of the messages binds it to:
   --  its fields are then the mapping's members.
   function Message_As_Data return Boolean
   is (Item.Message_Slot /= 0
       and then Slots (Item.Message_Slot).Kind = Value_Data);

   --  Where a loop over the calls one turn asked for has got to, which
   --  turn that is, and whether such a loop is running. One set of
   --  these, because a call loop inside a call loop is refused where it
   --  is compiled.
   Call_At      : Natural := 0;
   Call_Message : Natural := 0;
   In_Calls     : Boolean := False;

   --  How many calls the bound turn asked for.
   function Asked_Count return Natural is
      Where : constant Natural := Bound_Message;
   begin
      return (if Where = 0 or else Where > Count then 0
              else Conv.Call_Count (Messages, Where));
   end Asked_Count;

   --  And how many the running loop is walking, which is the turn it
   --  began on rather than whatever the name message holds now: a
   --  template that rebinds that name inside the loop must not change
   --  what loop.last answers about it.
   function Walking_Count return Natural
   is (if Call_Message = 0 or else Call_Message > Count then 0
       else Conv.Call_Count (Messages, Call_Message));

   --  Where a counting loop has got to, where it stops and what it steps
   --  by, and which name it writes each number to.
   --
   --  One set of these rather than one a depth: a counting loop inside
   --  another counting loop is refused where it is compiled, so there is
   --  never more than one running.
   Range_At    : Long_Long_Integer := 0;
   Range_Start : Long_Long_Integer := 0;
   Range_Stop  : Long_Long_Integer := 0;
   Range_Step  : Long_Long_Integer := 1;
   Range_Slot : Natural := 0;

   --  Whether the count has passed its stop, which depends on which way
   --  it is going.
   function Counting_On return Boolean
   is (if Range_Step > 0 then Range_At < Range_Stop
       else Range_At > Range_Stop);

   --  Append text to the output, reporting overflow once.
   procedure Put (Value : String) is
   begin
      if Overflow or else Value'Length = 0 then
         return;
      end if;
      if Last + Value'Length > Target'Length then
         Overflow := True;
         return;
      end if;
      Target (Target'First + Last .. Target'First + Last + Value'Length - 1) :=
        Value;
      Last := Last + Value'Length;
   end Put;

   --  Declared before Raw_Of because an indexed term's position is an
   --  expression, and reading one needs both of these.
   function Value_Of (Value : Operand) return String;

   --  Whether what is being evaluated is a condition rather than output.
   --  A condition may ask about a name the template never assigned; the
   --  output may not, and the difference is which of the two is running.
   Testing : Boolean := False;

   --  Value of one term in the current context, before its filter.
   --  The moment of rendering, written as a strftime format says. The
   --  directives are the ones the templates use to write a date into a
   --  system prompt -- day, month and year in numbers and in English
   --  names, the time, the weekday -- and one this engine has no
   --  answer for refuses where it is read rather than writing the
   --  letter. Local time, which is what the language's strftime writes.
   function Now_As (Format : String; Value : Term) return String is
      package Fmt renames Ada.Calendar.Formatting;

      Now    : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Zone   : constant Ada.Calendar.Time_Zones.Time_Offset :=
        Ada.Calendar.Time_Zones.UTC_Time_Offset (Now);
      Year   : constant Ada.Calendar.Year_Number := Fmt.Year (Now, Zone);
      Month  : constant Ada.Calendar.Month_Number := Fmt.Month (Now, Zone);
      Day    : constant Ada.Calendar.Day_Number := Fmt.Day (Now, Zone);
      Hour   : constant Fmt.Hour_Number := Fmt.Hour (Now, Zone);
      Minute : constant Fmt.Minute_Number := Fmt.Minute (Now, Zone);
      Second : constant Fmt.Second_Number := Fmt.Second (Now);
      Week   : constant Fmt.Day_Name := Fmt.Day_Of_Week (Now);

      Months : constant array (Ada.Calendar.Month_Number) of String (1 .. 9)
        := ["January  ", "February ", "March    ", "April    ",
            "May      ", "June     ", "July     ", "August   ",
            "September", "October  ", "November ", "December "];
      Days   : constant array (Fmt.Day_Name) of String (1 .. 9)
        := ["Monday   ", "Tuesday  ", "Wednesday", "Thursday ",
            "Friday   ", "Saturday ", "Sunday   "];

      --  The day's number in the year, counted from one.
      function Day_Of_Year return Natural is
         Lengths : constant array (Ada.Calendar.Month_Number) of Natural :=
           [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
         Leap    : constant Boolean :=
           (Year mod 4 = 0 and then Year mod 100 /= 0)
           or else Year mod 400 = 0;
         Total   : Natural := Day;
      begin
         for M in 1 .. Month - 1 loop
            Total := Total + Lengths (M)
              + (if M = 2 and then Leap then 1 else 0);
         end loop;
         return Total;
      end Day_Of_Year;

      function Two (Number : Natural) return String
      is ((if Number < 10 then "0" else "")
          & Model_Runner.Text.Image (Long_Long_Integer (Number)));

      function Plain (Number : Natural) return String
      is (Model_Runner.Text.Image (Long_Long_Integer (Number)));

      Result : Ada.Strings.Unbounded.Unbounded_String;
      Index  : Natural := Format'First;
   begin
      while Index <= Format'Last loop
         if Format (Index) /= '%' or else Index = Format'Last then
            Ada.Strings.Unbounded.Append (Result, Format (Index));
            Index := Index + 1;
         else
            declare
               --  A dash before the letter drops the leading zero, as
               --  the C library's strftime reads it.
               Bare   : constant Boolean := Format (Index + 1) = '-';
               Letter : constant Character :=
                 (if Bare and then Index + 2 <= Format'Last
                  then Format (Index + 2)
                  else Format (Index + 1));

               function Number (Value : Natural) return String
               is (if Bare then Plain (Value) else Two (Value));

               Piece : constant String :=
                 (case Letter is
                     when 'Y' => Plain (Year),
                     when 'y' => Two (Year mod 100),
                     when 'm' => Number (Month),
                     when 'd' => Number (Day),
                     when 'e' => (if Day < 10 then " " else "")
                                 & Plain (Day),
                     when 'H' => Number (Hour),
                     when 'I' => Number ((if Hour mod 12 = 0 then 12
                                          else Hour mod 12)),
                     when 'M' => Number (Minute),
                     when 'S' => Number (Second),
                     when 'p' => (if Hour < 12 then "AM" else "PM"),
                     when 'b' => Months (Month) (1 .. 3),
                     when 'B' => Model_Runner.Text.Trim (Months (Month)),
                     when 'a' => Days (Week) (1 .. 3),
                     when 'A' => Model_Runner.Text.Trim (Days (Week)),
                     when 'j' => Plain (Day_Of_Year),
                     when '%' => "%",
                     when others => "");
            begin
               if Piece'Length = 0 and then Letter /= '%' then
                  Refuse (Value.Offset, Value.Length,
                          E.Template_Unsupported_Construct);
                  return "";
               end if;
               Ada.Strings.Unbounded.Append (Result, Piece);
               Index := Index + (if Bare then 3 else 2);
            end;
         end if;
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end Now_As;

   --  A macro's body run from its entry to its return, and what it
   --  wrote: the output past the mark where the call began, taken back
   --  off the output and handed to the term. The arguments are read
   --  before the parameters are bound, because a macro that calls
   --  itself names its own parameters in the call; the parameters are
   --  bound fresh and given back afterwards, which is what makes the
   --  recursion a recursion rather than a loop over one set of names.
   function Run_Macro (Value : Term) return String is separate;

   --  How long the innermost loop is and where it is, one-based, for
   --  loop.length and loop.revindex: from the stack for the loops that
   --  keep their state there, and from the legacy variables otherwise.
   function Loop_Index return Long_Long_Integer is
   begin
      if Innermost_Is_New then
         return Long_Long_Integer (Loops (Loop_Depth).Index);
      elsif In_Calls then
         return Long_Long_Integer (Call_At);
      elsif Loop_Depth > 0 and then Loops (Loop_Depth).Kind = Legacy_Range
      then
         return (if Range_Step = 0 then 1
                 else (Range_At - Range_Start) / Range_Step + 1);
      end if;
      return Long_Long_Integer (Current) - Long_Long_Integer (Loop_Start) + 1;
   end Loop_Index;

   function Loop_Total return Natural is
   begin
      if Innermost_Is_New then
         return Loops (Loop_Depth).Total;
      elsif In_Calls then
         return Walking_Count;
      elsif Loop_Depth > 0 and then Loops (Loop_Depth).Kind = Legacy_Range
      then
         if Range_Step = 0 then
            return 1;
         end if;
         declare
            Span : constant Long_Long_Integer :=
              (if Range_Step > 0 then Range_Stop - Range_Start
               else Range_Start - Range_Stop);
            Each : constant Long_Long_Integer := abs Range_Step;
         begin
            return (if Span <= 0 then 0
                    else Natural ((Span + Each - 1) / Each));
         end;
      end if;
      return Natural'Max (Loop_Stop - Loop_Start + 1, 0);
   end Loop_Total;

   function Raw_Of (Value : Term) return String is separate;

   --  What one method does to the text it is written after.
   function Applied (Step : Method_Step; Held : String) return String is
      --  The characters it takes off, or the marker it cuts at. An
      --  absent argument means whitespace, which is what the language
      --  means by strip with nothing in its brackets.
      Argument : constant String :=
        (if Step.At_Operand = 0 then " " & ASCII.HT & ASCII.LF & ASCII.CR
         else Value_Of (Item.Operands.all (Step.At_Operand)));

      function Is_Trimmed (Letter : Character) return Boolean
      is (for some Wanted of Argument => Wanted = Letter);

      First : Natural := Held'First;
      Last  : Natural := Held'Last;
   begin
      case Step.Kind is
         when Method_None | Method_Starts_With | Method_Ends_With
            | Method_Replace | Method_Items | Method_Index
            | Method_Member | Method_Keys | Method_Values | Method_Get
            | Method_Upper | Method_Lower | Method_Title
            | Method_Capitalize | Method_Format =>
            --  These are answered on values, in Method_On.
            return Held;

         when Method_Strip | Method_Left_Strip | Method_Right_Strip =>
            if Step.Kind /= Method_Right_Strip then
               while First <= Last and then Is_Trimmed (Held (First)) loop
                  First := First + 1;
               end loop;
            end if;
            if Step.Kind /= Method_Left_Strip then
               while Last >= First and then Is_Trimmed (Held (Last)) loop
                  Last := Last - 1;
               end loop;
            end if;
            return Held (First .. Last);

         when Method_Cut_From | Method_Cut_To =>
            declare
               Length : constant Long_Long_Integer :=
                 Long_Long_Integer (Held'Length);
               Cut    : Long_Long_Integer := Number_Of (Argument);
            begin
               if Cut < 0 then
                  Cut := Length + Cut;
               end if;
               Cut := Long_Long_Integer'Max
                 (0, Long_Long_Integer'Min (Cut, Length));

               if Step.Kind = Method_Cut_From then
                  return Held (Held'First + Natural (Cut) .. Held'Last);
               else
                  return Held (Held'First .. Held'First + Natural (Cut) - 1);
               end if;
            end;

         when Method_Split_Whole =>
            --  A cut nothing said the side of. The list it answers with
            --  has no spelling here, and printing one end of it because
            --  that is the end this engine could give would be a guess.
            Refuse (0, 0, E.Template_Unsupported_Construct);
            return "";

         when Method_Split_Once_After | Method_Split_Once_Rest =>
            --  What follows the first marker; with none, the second
            --  piece is not there and the last piece is the whole.
            if Argument'Length > 0 and then Held'Length >= Argument'Length
            then
               for Start in Held'First .. Held'Last - Argument'Length + 1
               loop
                  if Held (Start .. Start + Argument'Length - 1) = Argument
                  then
                     return Held (Start + Argument'Length .. Held'Last);
                  end if;
               end loop;
            end if;
            return (if Step.Kind = Method_Split_Once_After then ""
                    else Held);

         when Method_Split_First | Method_Split_Last =>
            --  The text before the first marker, or after the last one.
            --  A text with no marker in it is one piece, and both ends of
            --  one piece are the piece.
            if Argument'Length = 0 or else Held'Length < Argument'Length
            then
               return Held;
            end if;

            if Step.Kind = Method_Split_First then
               for Start in Held'First .. Held'Last - Argument'Length + 1
               loop
                  if Held (Start .. Start + Argument'Length - 1) = Argument
                  then
                     return Held (Held'First .. Start - 1);
                  end if;
               end loop;
            else
               for Start in reverse
                 Held'First .. Held'Last - Argument'Length + 1
               loop
                  if Held (Start .. Start + Argument'Length - 1) = Argument
                  then
                     return Held (Start + Argument'Length .. Held'Last);
                  end if;
               end loop;
            end if;
            return Held;
      end case;
   end Applied;

   --  Text as a JSON string: the quotes, the escapes JSON requires and
   --  nothing else. Measured before it is written, so that a long value
   --  costs the room it needs rather than the room the worst case would.
   function Quoted (Value : String) return String is
      Digits_16 : constant String := "0123456789abcdef";

      --  The control characters JSON writes with a letter are named
      --  outright; the rest of them go out as a number, and the ranges
      --  say which are which without either overlapping the other.
      function Room_For (Letter : Character) return Natural
      is (case Letter is
            when '"' | '\' | ASCII.LF | ASCII.CR | ASCII.HT
               | ASCII.BS | ASCII.FF => 2,
            when Character'Val (0) .. Character'Val (7)
               | Character'Val (11)
               | Character'Val (14) .. Character'Val (31) => 6,
            when others => 1);

      Needed : Natural := 2;
      Filled : Natural := 0;
   begin
      for Letter of Value loop
         Needed := Needed + Room_For (Letter);
      end loop;

      declare
         Room : String (1 .. Needed);

         procedure Put_Text (Piece : String) is
         begin
            Room (Filled + 1 .. Filled + Piece'Length) := Piece;
            Filled := Filled + Piece'Length;
         end Put_Text;
      begin
         Put_Text ("""");
         for Letter of Value loop
            case Letter is
               when '"'      => Put_Text ("\""");
               when '\'      => Put_Text ("\\");
               when ASCII.LF => Put_Text ("\n");
               when ASCII.CR => Put_Text ("\r");
               when ASCII.HT => Put_Text ("\t");
               when ASCII.BS => Put_Text ("\b");
               when ASCII.FF => Put_Text ("\f");
               when Character'Val (0) .. Character'Val (7)
                  | Character'Val (11)
                  | Character'Val (14) .. Character'Val (31) =>
                  Put_Text
                    ("\u00"
                     & Digits_16
                         (Digits_16'First + Character'Pos (Letter) / 16)
                     & Digits_16
                         (Digits_16'First + Character'Pos (Letter) mod 16));
               when others =>
                  Put_Text ([1 => Letter]);
            end case;
         end loop;
         Put_Text ("""");
         return Room (1 .. Filled);
      end;
   end Quoted;

   --  A call's arguments -- a JSON object -- written as MiniCPM's
   --  parameter elements. The value the term holds is that object as text;
   --  this reads its top-level pairs and writes a <param name="k">v</param>
   --  for each, the value plain (a JSON string unquoted) and inside a
   --  <![CDATA[..]]> block when it holds a '<', an '&' or a newline.
   function Params_Of (Src : String; Qwen : Boolean := False) return String is separate;

   --  What Qwen3-Coder's own template makes of one tool: the walk its
   --  render_item_list macro and its two mapping loops make over the
   --  definition's JSON, written out in Ada over the same text. The JSON
   --  is the definition as the tools package spells it -- one line, a
   --  space after each colon and comma, escapes decoded -- which is the
   --  spelling `| tojson` gives, so a nested mapping is copied as it
   --  stands. Where that template writes a value with `| string` it is
   --  Python's str of it: a number as itself, true as True, null as
   --  None, a list as its repr with single quotes.
   function Qwen_Tool_Of (Src : String) return String is separate;

   --  Value of one term with its filter applied.
   --  What one filter makes of the text before it. The three that read
   --  the term rather than its text -- tojson and the two parameter
   --  writers -- are answered in Value_Of, where the term is at hand.
   --  Text with its case changed, character by Unicode character
   --  rather than byte by byte: the UTF-8 is decoded, each character
   --  folded as the standard library folds it, and the text encoded
   --  again. An 'ß' has no single upper case and becomes "SS", as
   --  Python writes it.
   type Recasing is (Lower, Upper, Capital, Title);

   function Recased (Held : String; How : Recasing) return String is
      package WW renames Ada.Wide_Wide_Characters.Handling;
      package Coding renames Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
      Wide   : constant Wide_Wide_String := Coding.Decode (Held);
      Result : Wide_Wide_String (1 .. 2 * Wide'Length);
      Filled : Natural := 0;
      Fresh  : Boolean := True;
      Sharp  : constant Wide_Wide_Character := Wide_Wide_Character'Val (223);

      procedure Add (C : Wide_Wide_Character) is
      begin
         Filled := Filled + 1;
         Result (Filled) := C;
      end Add;

      procedure Add_Upper (C : Wide_Wide_Character) is
      begin
         if C = Sharp then
            Add ('S');
            Add ('S');
         else
            Add (WW.To_Upper (C));
         end if;
      end Add_Upper;
   begin
      for Index in Wide'Range loop
         declare
            C : constant Wide_Wide_Character := Wide (Index);
         begin
            case How is
               when Lower =>
                  Add (WW.To_Lower (C));
               when Upper =>
                  Add_Upper (C);
               when Capital =>
                  if Index = Wide'First then
                     Add_Upper (C);
                  else
                     Add (WW.To_Lower (C));
                  end if;
               when Title =>
                  if C in ' ' | '-' | '(' | '{' | '[' | '<'
                    or else WW.Is_Space (C)
                    or else C = Wide_Wide_Character'Val (10)
                    or else C = Wide_Wide_Character'Val (9)
                    or else C = Wide_Wide_Character'Val (13)
                  then
                     Add (C);
                     Fresh := True;
                  elsif Fresh then
                     Add_Upper (C);
                     Fresh := False;
                  else
                     Add (WW.To_Lower (C));
                  end if;
            end case;
         end;
      end loop;
      return Coding.Encode (Result (1 .. Filled));
   exception
      when others =>
         --  Bytes that are not UTF-8 are left as they are.
         return Held;
   end Recased;

   function Filtered (Step : Filter_Step; Held : String) return String is
   begin
      case Step.Kind is
         when Filter_None | Filter_String | Filter_Safe | Filter_JSON
            | Filter_Params | Filter_Qwen_Params | Filter_Qwen_Tool
            | Filter_Min | Filter_Join | Filter_Map | Filter_Select
            | Filter_Reject | Filter_Select_Attr | Filter_Reject_Attr
            | Filter_Sort | Filter_Dict_Sort | Filter_Indent
            | Filter_Unique | Filter_List | Filter_First | Filter_Last
            | Filter_Float | Filter_Round | Filter_Abs | Filter_Sum
            | Filter_Urlencode | Filter_Batch | Filter_Slice
            | Filter_Groupby | Filter_Attr | Filter_Wordwrap
            | Filter_Truncate | Filter_Center | Filter_Format
            | Filter_Striptags | Filter_Pprint | Filter_Random
            | Filter_Reverse | Filter_Max =>
            return Held;

         when Filter_Trim =>
            --  Whitespace -- line breaks too, as Python's strip takes
            --  them -- or the characters named, off both ends.
            declare
               Chars : constant String :=
                 (if Step.Arg1 = 0
                  then ' ' & ASCII.HT & ASCII.LF & ASCII.VT & ASCII.FF
                       & ASCII.CR
                  else Value_Of (Item.Operands.all (Step.Arg1)));
               First : Natural := Held'First;
               Last  : Natural := Held'Last;
            begin
               while First <= Last
                 and then (for some C of Chars => C = Held (First))
               loop
                  First := First + 1;
               end loop;
               while Last >= First
                 and then (for some C of Chars => C = Held (Last))
               loop
                  Last := Last - 1;
               end loop;
               return Held (First .. Last);
            end;

         when Filter_Length =>
            return Model_Runner.Text.Image (Long_Long_Integer (Held'Length));

         when Filter_Lower =>
            return Recased (Held, Lower);

         when Filter_Upper =>
            return Recased (Held, Upper);

         when Filter_Capitalize =>
            --  The first letter up and the rest down, as the language
            --  does it.
            return Recased (Held, Capital);

         when Filter_Title =>
            --  Every word's first letter up and the rest down, a word
            --  beginning after a blank or one of the language's own
            --  word-openers: '-', '(', '{', '[', '<'.
            return Recased (Held, Title);

         when Filter_Int =>
            return Model_Runner.Text.Image (Number_Of (Held));

         when Filter_Default =>
            --  The stand-in where the value is empty, none or never set;
            --  the value where it is anything else.
            if Held'Length = 0 then
               return Value_Of (Item.Operands.all (Step.Arg1));
            end if;
            return Held;

         when Filter_Replace =>
            declare
               Old_Text : constant String :=
                 Value_Of (Item.Operands.all (Step.Arg1));
               New_Text : constant String :=
                 Value_Of (Item.Operands.all (Step.Arg2));
               Result   : Ada.Strings.Unbounded.Unbounded_String;
               Index    : Natural := Held'First;

               --  At most this many, where a count was given.
               Allowed  : Long_Long_Integer :=
                 (if Step.Arg3 = 0 then Long_Long_Integer'Last
                  else Number_Of (Value_Of (Item.Operands.all (Step.Arg3))));
            begin
               if Old_Text'Length = 0 then
                  return Held;
               end if;
               while Index <= Held'Last loop
                  if Allowed > 0
                    and then Index + Old_Text'Length - 1 <= Held'Last
                    and then Held (Index .. Index + Old_Text'Length - 1)
                             = Old_Text
                  then
                     Ada.Strings.Unbounded.Append (Result, New_Text);
                     Index := Index + Old_Text'Length;
                     Allowed := Allowed - 1;
                  else
                     Ada.Strings.Unbounded.Append (Result, Held (Index));
                     Index := Index + 1;
                  end if;
               end loop;
               return Ada.Strings.Unbounded.To_String (Result);
            end;
      end case;
   end Filtered;

   --  A term as a value: what it names, then each method in turn, then
   --  each filter, each taking what the one before it made.
   --  The elements of a list as spans, for the filters that walk one.
   Max_Elements : constant := 4096;
   type Span_Array is array (1 .. Max_Elements) of Span;

   procedure Elements_Of
     (Src : String; Spans : out Span_Array; Count : out Natural);
   function List_Of
     (Src : String; Spans : Span_Array; Count : Natural) return Held;

   --  A value as the text it stands as in a prompt. Message content given
   --  as parts -- a picture and words -- renders inline, the words with a
   --  marker where each picture stands, so a string method or a text
   --  filter that a template runs over its content sees the same text a
   --  bare mention would print and keeps the picture rather than reading
   --  the parts' JSON. A value that is not such parts, one where no marker
   --  was given, or a value read only to test a condition, prints as it
   --  prints. Every place that coerces a value to prompt text reads it
   --  here, so they agree.
   function Prompt_Text (Value : Held) return String
   is (if not Testing and then Value.Kind = Value_Data
         and then Value.Parts
         and then Image_Marker'Length + Video_Marker'Length > 0
       then Conv.Prompt_Of_Parts
              (Text_Of (Value), Image_Marker, Video_Marker)
       else Printed (Value));

   function Method_On (Value : Held; Step : Method_Step) return Held is separate;

   --  Any value that can be walked, as a JSON list: a list as it is,
   --  the tools as their definitions, a list of messages as objects
   --  with a role, a content and the calls the turn asked for, one
   --  turn's calls as objects with a type and a function. What the list
   --  filters walk, so that "messages | selectattr('role', 'equalto',
   --  'user')" is a question with an answer.
   function Listed (Value : Held) return String is
      R : Ada.Strings.Unbounded.Unbounded_String;

      procedure Add (Text : String) is
      begin
         Ada.Strings.Unbounded.Append (R, Text);
      end Add;

      --  A call as the conversation's JSON holds one: its type, and
      --  its name and arguments under function.
      procedure Add_Call (At_Message, Which : Positive) is
      begin
         Add ("{""type"": ""function"", ""function"": {""name"": "
              & Quoted (Conv.Call_Name (Messages, At_Message, Which))
              & ", ""arguments"": "
              & Conv.Call_Arguments (Messages, At_Message, Which) & "}}");
      end Add_Call;
   begin
      case Value.Kind is
         when Value_Data | Value_JSON | Value_Text =>
            return JSON_Text (Value);
         when Value_Tools =>
            Add ("[");
            for Index in 1 .. Tool_Count loop
               if Index > 1 then
                  Add (", ");
               end if;
               Add (Offered_Tools.Definition (Tools.all, Index));
            end loop;
            Add ("]");
         when Value_List =>
            Add ("[");
            for At_Message in Value.Start .. Last_Of (Value) loop
               if At_Message > Value.Start then
                  Add (", ");
               end if;
               Add ("{""role"": "
                    & Quoted (Conv.Role_Name
                                (Conv.Sender_At (Messages, At_Message)))
                    & ", ""content"": "
                    & (if Conv.Parts_At (Messages, At_Message) /= ""
                       then Conv.Parts_At (Messages, At_Message)
                       else Quoted (Conv.Content_At (Messages, At_Message))));
               if Conv.Call_Count (Messages, At_Message) > 0 then
                  Add (", ""tool_calls"": [");
                  for Which in 1 .. Conv.Call_Count (Messages, At_Message)
                  loop
                     if Which > 1 then
                        Add (", ");
                     end if;
                     Add_Call (At_Message, Which);
                  end loop;
                  Add ("]");
               end if;
               Add ("}");
            end loop;
            Add ("]");
         when Value_Call =>
            if Value.Index /= 0 or else Value.Start = 0
              or else Value.Start > Count
            then
               return "[]";
            end if;
            Add ("[");
            for Which in 1 .. Conv.Call_Count (Messages, Value.Start) loop
               if Which > 1 then
                  Add (", ");
               end if;
               Add_Call (Value.Start, Which);
            end loop;
            Add ("]");
         when others =>
            return "[]";
      end case;
      return Ada.Strings.Unbounded.To_String (R);
   end Listed;

   --  JSON text written out again with each container's members on
   --  lines of their own, Width blanks deeper a level, as Python's
   --  json.dumps(indent=Width) writes it.
   function Indented_JSON (Src : String; Width : Natural) return String is
      R     : Ada.Strings.Unbounded.Unbounded_String;
      Level : Natural := 0;
      Quote : Boolean := False;
      Index : Natural := Src'First;

      procedure Break_Line is
         Pad : constant String (1 .. Level * Width) := [others => ' '];
      begin
         Ada.Strings.Unbounded.Append (R, ASCII.LF & Pad);
      end Break_Line;

      --  Whether the container opening at Index is empty.
      function Empty_Ahead return Boolean is
         Look : constant Natural := Past_Blanks (Src, Index + 1);
      begin
         return Look <= Src'Last and then Src (Look) in ']' | '}';
      end Empty_Ahead;
   begin
      while Index <= Src'Last loop
         declare
            C : constant Character := Src (Index);
         begin
            if Quote then
               Ada.Strings.Unbounded.Append (R, C);
               if C = '\' and then Index < Src'Last then
                  Index := Index + 1;
                  Ada.Strings.Unbounded.Append (R, Src (Index));
               elsif C = '"' then
                  Quote := False;
               end if;
            elsif C = '"' then
               Quote := True;
               Ada.Strings.Unbounded.Append (R, C);
            elsif C in '[' | '{' then
               Ada.Strings.Unbounded.Append (R, C);
               if Empty_Ahead then
                  Index := Past_Blanks (Src, Index + 1);
                  Ada.Strings.Unbounded.Append (R, Src (Index));
               else
                  Level := Level + 1;
                  Break_Line;
               end if;
            elsif C in ']' | '}' then
               Level := (if Level > 0 then Level - 1 else 0);
               Break_Line;
               Ada.Strings.Unbounded.Append (R, C);
            elsif C = ',' then
               Ada.Strings.Unbounded.Append (R, C);
               Break_Line;
            elsif C = ':' then
               Ada.Strings.Unbounded.Append (R, ": ");
            elsif C in ' ' | ASCII.LF | ASCII.CR | ASCII.HT then
               null;
            else
               Ada.Strings.Unbounded.Append (R, C);
            end if;
         end;
         Index := Index + 1;
      end loop;
      return Ada.Strings.Unbounded.To_String (R);
   end Indented_JSON;

   --  Whether a value passes a test named in a select or reject, with
   --  the argument the test takes where it takes one.
   function Passes (V : Held; Test : String; Arg : Natural) return Boolean
   is
   begin
      if Test = "" then
         return Is_Truthy (V);
      elsif Test = "defined" then
         return V.Kind /= Value_Undefined;
      elsif Test = "undefined" then
         return V.Kind = Value_Undefined;
      elsif Test = "none" then
         return V.Kind = Value_None;
      elsif Test = "string" then
         return V.Kind = Value_Text;
      elsif Test = "number" then
         return V.Kind in Value_Number | Value_Boolean
           or else (V.Kind = Value_Data
                    and then Text_Of (V) in "true" | "false");
      elsif Test = "boolean" then
         return V.Kind = Value_Boolean
           or else (V.Kind = Value_Data
                    and then Text_Of (V) in "true" | "false");
      elsif Test = "mapping" then
         return V.Kind in Value_JSON | Value_Message
           or else (V.Kind = Value_Call and then V.Index /= 0)
           or else (V.Kind = Value_Data and then Is_JSON_Mapping (Text_Of (V)));
      elsif Test = "iterable" then
         return V.Kind in Value_Text | Value_Data | Value_JSON | Value_Tools
                          | Value_List;
      elsif Test = "true" then
         return V.Kind = Value_Boolean and then V.Start = 1;
      elsif Test = "false" then
         return V.Kind = Value_Boolean and then V.Start = 0;
      elsif Test in "equalto" | "eq" | "==" | "ne" | "!=" then
         declare
            Wanted : constant String :=
              (if Arg = 0 then "" else Value_Of (Item.Operands.all (Arg)));
            Same   : constant Boolean := Printed (V) = Wanted;
         begin
            return (if Test in "ne" | "!=" then not Same else Same);
         end;
      elsif Test = "in" then
         declare
            Held_List : constant Held :=
              (if Arg = 0 then Nothing
               else Held_Of (Item.Operands.all (Arg)));
            Src : constant String := JSON_Text (Held_List);
            Cursor : Natural;
            Piece  : Span;
            More   : Boolean;
         begin
            if not Is_JSON_List (Src) then
               return False;
            end if;
            Cursor := Src'First + 1;
            loop
               Next_Element (Src, Cursor, Piece, More);
               exit when not More;
               if Printed (Read_Out (Src (Piece.First .. Piece.Last)))
                  = Printed (V)
               then
                  return True;
               end if;
            end loop;
            return False;
         end;
      end if;
      return False;
   end Passes;

   procedure Elements_Of
     (Src : String; Spans : out Span_Array; Count : out Natural) is
      Cursor : Natural;
      Piece  : Span;
      More   : Boolean;
   begin
      Count := 0;
      if not Is_JSON_List (Src) then
         return;
      end if;
      Cursor := Src'First + 1;
      loop
         Next_Element (Src, Cursor, Piece, More);
         exit when not More;
         if Count >= Max_Elements then
            --  A list longer than the filters walk refuses, naming the
            --  bound, rather than answering for the front of it.
            if not Refused then
               Refused_Limit := Max_Elements;
            end if;
            Refuse (0, 0, E.Template_Variables_Too_Large);
            return;
         end if;
         Count := Count + 1;
         Spans (Count) := Piece;
      end loop;
   end Elements_Of;

   --  A list rebuilt from the spans kept, in order.
   function List_Of
     (Src : String; Spans : Span_Array; Count : Natural) return Held
   is
      R : Ada.Strings.Unbounded.Unbounded_String;
   begin
      Ada.Strings.Unbounded.Append (R, "[");
      for Index in 1 .. Count loop
         if Index > 1 then
            Ada.Strings.Unbounded.Append (R, ", ");
         end if;
         Ada.Strings.Unbounded.Append
           (R, Src (Spans (Index).First .. Spans (Index).Last));
      end loop;
      Ada.Strings.Unbounded.Append (R, "]");
      return As_Data (Ada.Strings.Unbounded.To_String (R));
   end List_Of;

   --  Whether one element sorts before another: numbers by value,
   --  anything else by its text, case folded unless asked otherwise.
   function Before (A, B : Held; Fold : Boolean) return Boolean is
   begin
      if A.Kind = Value_Number and then B.Kind = Value_Number then
         return Real_Of (Text_Of (A)) < Real_Of (Text_Of (B));
      end if;
      if Fold then
         return Recased (Printed (A), Lower) < Recased (Printed (B), Lower);
      end if;
      return Printed (A) < Printed (B);
   end Before;

   function Filter_On (Value : Held; Step : Filter_Step) return Held is separate;

   --  What is inside a bracket after a value: a position where it is
   --  a number, and a member's name where it is not -- t['function']
   --  and t.function are the same member.
   function Indexed (Value : Held; Key : String) return Held is
      Numeric : constant Boolean :=
        Key'Length > 0
        and then (for all C of Key => C in '0' .. '9' | '-')
        and then Key (Key'Last) in '0' .. '9';
   begin
      if Numeric then
         return Element_At (Value, Number_Of (Key));
      end if;
      --  No key -- what a name never set reads as -- finds nothing,
      --  as type_map[spec.type] does where spec has no type; walking
      --  no path at all would answer the mapping itself.
      if Key'Length = 0 then
         return Nothing;
      end if;
      return Along (Value, Key);
   end Indexed;

   --  One message as the JSON its list would hold it as.
   function Element_Of_Listed (One : Held) return String is
      Whole : constant String :=
        Listed ((Kind => Value_List, Start => One.Start, others => <>));
      Cursor : Natural := Whole'First + 1;
      Piece  : Span;
      Found  : Boolean;
   begin
      if One.Start = 0 or else One.Start > Count then
         return "null";
      end if;
      Next_Element (Whole, Cursor, Piece, Found);
      return (if Found then Whole (Piece.First .. Piece.Last) else "null");
   end Element_Of_Listed;

   --  One operand as JSON, for a list or mapping written out: a number
   --  where it is one, a mapping or list as its JSON, none as null,
   --  a truth as one, and text as a JSON string.
   function Encoded (Element : Operand) return String is
   begin
      if Element.Count = 1 then
         declare
            One : constant Held := Resolve (Element.Terms (1));
         begin
            if One.Kind in Value_Data | Value_Number | Value_None
                           | Value_Boolean | Value_JSON
            then
               return JSON_Text (One);
            elsif Element.Terms (1).Numeric then
               return Model_Runner.Text.Image (Number_Of (Printed (One)));
            elsif One.Kind in Value_Tools | Value_List | Value_Call then
               --  One call is an object, a turn's calls a list.
               return Structure_Of (One);
            elsif One.Kind = Value_Message then
               return Element_Of_Listed (One);
            else
               return Quoted (Printed (One));
            end if;
         end;
      elsif Is_Sum (Element) then
         return Value_Of (Element);
      end if;
      return Quoted (Value_Of (Element));
   end Encoded;

   function Base_Of (Value : Term) return Held is separate;

   function Resolve (Value : Term) return Held is
      R : Held := Base_Of (Value);
   begin
      for M in 1 .. Value.Chained loop
         R := Method_On (R, Value.Methods (M));
      end loop;
      for F in 1 .. Value.Filtered loop
         R := Filter_On (R, Value.Filters (F));
      end loop;
      return R;
   end Resolve;

   function Value_Of (Value : Term) return String is
      R : constant Held := Resolve (Value);
   begin
      case R.Kind is
         when Value_Undefined =>
            --  A name never assigned is nothing in a condition and a
            --  refusal in the output, for the reason Raw_Of gives.
            if not Testing and then Value.Kind = Term_Variable
              and then Value.Path_Len = 0 and then not Value.Indexes
            then
               Refuse (Item.Names (Value.Offset).Offset,
                       Item.Names (Value.Offset).Length,
                       E.Template_Unknown_Variable);
            end if;
            return "";
         when Value_Boolean | Value_None =>
            --  Truth in a condition, and Python's spelling in the
            --  output.
            if Testing then
               return (if Is_Truthy (R) then "true" else "");
            end if;
            return Printed (R);
         when Value_Tools | Value_List | Value_Message | Value_Call
            | Value_JSON =>
            --  Positions, not text. A condition asks whether there is
            --  something there; the output may not print one.
            if Testing then
               return (if Is_Truthy (R) then "true" else "");
            end if;
            if Value.Kind = Term_Variable then
               Refuse (Item.Names (Value.Offset).Offset,
                       Item.Names (Value.Offset).Length,
                       E.Template_Unsupported_Construct);
            else
               Refuse (Value.Offset, Value.Length,
                       E.Template_Unsupported_Construct);
            end if;
            return "";
         when others =>
            --  A message's content parts, where the value is wanted as
            --  text and the picture markers are known, render inline:
            --  the words and a marker where each picture stands.
            if not Testing and then R.Kind = Value_Data and then R.Parts
              and then Image_Marker'Length + Video_Marker'Length > 0
            then
               return Conv.Prompt_Of_Parts
                 (Text_Of (R), Image_Marker, Video_Marker);
            end if;
            return Printed (R);
      end case;
   end Value_Of;

   --  Write an operand straight to the output. Emitting term by term
   --  avoids a temporary the size of the whole target, which message
   --  content can legitimately approach.
   --  Whether an operand written into it prints as one number or as one
   --  run of text.
   --
   --  Both readers of an operand ask this and they have to agree: a
   --  template that works a position out in a set and prints the same
   --  expression elsewhere means the same thing in both places.
   --
   --  A subtraction is a sum outright: nothing else is written with a
   --  minus. A plus is one when every term of it is a number by
   --  construction -- a bare number, a loop counter, a length -- which
   --  is the language's own rule read off what the terms are rather than
   --  off what they happen to hold. Two pieces of text joined with a
   --  plus are still run together, and two numbers added: a template
   --  asking for messages[loop.index0 + 1] means the message after this
   --  one and not the one at position "01".
   --  Text a filter said was safe -- 'x' | safe -- is markup, and in
   --  Python markup added to text escapes the text: "'"|safe + name
   --  writes the name with its quotes and ampersands as entities, on
   --  either side of the plus, and the sum is markup from there on.
   --  A run of plain additions with markup in it is joined that way.
   function Is_Markup (T : Term) return Boolean
   is (T.Filtered > 0 and then T.Filters (T.Filtered).Kind = Filter_Safe);

   function Has_Markup (Value : Operand) return Boolean is
   begin
      if Value.Count < 2 then
         return False;
      end if;
      for Index in 2 .. Value.Count loop
         if Value.Terms (Index).Join /= Join_Plus then
            return False;
         end if;
      end loop;
      return (for some Index in 1 .. Value.Count =>
                Is_Markup (Value.Terms (Index)))
        and then not Is_Sum (Value);
   end Has_Markup;

   function Markup_Joined (Value : Operand) return String is
      function Escaped (Text : String) return String is
         R : Ada.Strings.Unbounded.Unbounded_String;
      begin
         for C of Text loop
            case C is
               when '&' => Ada.Strings.Unbounded.Append (R, "&amp;");
               when '<' => Ada.Strings.Unbounded.Append (R, "&lt;");
               when '>' => Ada.Strings.Unbounded.Append (R, "&gt;");
               when '"' => Ada.Strings.Unbounded.Append (R, "&#34;");
               when ''' => Ada.Strings.Unbounded.Append (R, "&#39;");
               when others => Ada.Strings.Unbounded.Append (R, C);
            end case;
         end loop;
         return Ada.Strings.Unbounded.To_String (R);
      end Escaped;

      R      : Ada.Strings.Unbounded.Unbounded_String;
      Markup : Boolean := False;
   begin
      for Index in 1 .. Value.Count loop
         declare
            Piece : constant String := Value_Of (Value.Terms (Index));
            Safe  : constant Boolean := Is_Markup (Value.Terms (Index));
         begin
            if Markup then
               Ada.Strings.Unbounded.Append
                 (R, (if Safe then Piece else Escaped (Piece)));
            elsif Safe then
               R := Ada.Strings.Unbounded.To_Unbounded_String
                 (Escaped (Ada.Strings.Unbounded.To_String (R)) & Piece);
               Markup := True;
            else
               Ada.Strings.Unbounded.Append (R, Piece);
            end if;
         end;
      end loop;
      return Ada.Strings.Unbounded.To_String (R);
   end Markup_Joined;

   --  Text times a whole number, either way round: "<tok>" * n.
   function Is_Repetition (Value : Operand) return Boolean is
   begin
      if Value.Count /= 2 or else Value.Terms (2).Join /= Join_Times then
         return False;
      end if;
      declare
         Left  : constant Held := Resolve (Value.Terms (1));
         Right : constant Held := Resolve (Value.Terms (2));
      begin
         return (Left.Kind = Value_Text) /= (Right.Kind = Value_Text)
           and then Left.Kind in Value_Text | Value_Number
           and then Right.Kind in Value_Text | Value_Number;
      end;
   end Is_Repetition;

   function Is_Sum (Value : Operand) return Boolean is
   begin
      if Value.Count <= 1 then
         return False;
      end if;

      --  A '~' anywhere makes the whole of it text: the language turns
      --  both sides of one into text, and a number beside text is text.
      for Index in 2 .. Value.Count loop
         if Value.Terms (Index).Join = Join_Concat then
            return False;
         end if;
      end loop;

      for Index in 2 .. Value.Count loop
         if Value.Terms (Index).Join /= Join_Plus then
            return True;
         end if;
      end loop;

      if (for all Index in 1 .. Value.Count =>
            Value.Terms (Index).Numeric)
      then
         return True;
      end if;

      --  Or every term is worth a number when it is read, which the
      --  language decides then and not when the template is compiled:
      --  a name holds what it was assigned. Asked only of terms that
      --  cost nothing to read twice -- names, numbers, loop counters,
      --  bracketed groups -- and answered no for anything else, which
      --  runs together as it always did.
      for Index in 1 .. Value.Count loop
         declare
            T : Term renames Value.Terms (Index);
         begin
            if T.Kind not in Term_Literal | Term_Variable | Term_Group
                             | Term_Loop_Index_Zero | Term_Loop_Index_One
              or else T.Chained > 0 or else T.Filtered > 0
              or else Resolve (T).Kind /= Value_Number
            then
               return False;
            end if;
         end;
      end loop;
      return True;
   end Is_Sum;

   --  Whether a '+' joins text to a list or a mapping, which the
   --  language refuses -- a message whose content is a list of parts,
   --  handed to a template that writes "'<|user|>' + message.content"
   --  -- and which this refuses too, naming the join, rather than
   --  running the text and the list's spelling together.
   function Mixes_Text_And_Data (Value : Operand) return Boolean is
   begin
      if Value.Count < 2 then
         return False;
      end if;
      for Index in 2 .. Value.Count loop
         if Value.Terms (Index).Join = Join_Plus then
            declare
               Left  : constant Held := Resolve (Value.Terms (Index - 1));
               Right : constant Held := Resolve (Value.Terms (Index));
               function Is_Data (H : Held) return Boolean
               is (H.Kind = Value_Data);
            begin
               if Is_Data (Left) /= Is_Data (Right)
                 and then (Left.Kind in Value_Text | Value_Data)
                 and then (Right.Kind in Value_Text | Value_Data)
               then
                  --  A picture's parts added to text render inline where
                  --  the markers are known; only refuse where they are
                  --  not, so the join is never run together as spelling.
                  if (Image_Marker'Length + Video_Marker'Length > 0)
                    and then ((Left.Kind = Value_Data and then Left.Parts)
                              or else
                              (Right.Kind = Value_Data and then Right.Parts))
                  then
                     null;
                  else
                     Refuse (Value.Terms (Index).Join_At,
                             Value.Terms (Index).Join_Len,
                             E.Template_Unsupported_Construct);
                     return True;
                  end if;
               end if;
            end;
         end if;
      end loop;
      return False;
   end Mixes_Text_And_Data;

   procedure Emit_Operand (Value : Operand) is
   begin
      if Has_Markup (Value) then
         Put (Markup_Joined (Value));
         return;
      end if;
      --  A sum is printed as the number it comes to, and anything else
      --  one term at a time: a run of text is written out as it is
      --  reached rather than gathered up first, because what a template
      --  prints has no bound worth holding in one place.
      if Is_Sum (Value) then
         Put (Value_Of (Value));
         return;
      end if;
      if Mixes_Text_And_Data (Value) then
         return;
      end if;

      for Index in 1 .. Value.Count loop
         Put (Value_Of (Value.Terms (Index)));
      end loop;
   end Emit_Operand;

   --  The stack buffer an operand's text is run together in. Conditions
   --  compare roles, short literals and boolean markers, which fit; a
   --  longer operand carries on in an unbounded string.
   Max_Comparison : constant := 1024;

   --  Concatenated value of an operand, for use in a comparison.
   --  A term's value read as a whole number, or zero where it is not
   --  one. Zero rather than an error, because a template comparing a name
   --  it never assigned is asking about nothing, and answering that with
   --  a refusal would refuse a branch nobody takes.
   function Number_Of (Text : String) return Long_Long_Integer is
      Result : Long_Long_Integer := 0;
      Signed : Boolean := False;
      Index  : Natural := Text'First;
   begin
      while Index <= Text'Last and then Text (Index) = ' ' loop
         Index := Index + 1;
      end loop;

      if Index <= Text'Last and then Text (Index) = '-' then
         Signed := True;
         Index := Index + 1;
      end if;

      if Index > Text'Last or else Text (Index) not in '0' .. '9' then
         return 0;
      end if;

      while Index <= Text'Last and then Text (Index) in '0' .. '9' loop
         Result := Result * 10
           + Long_Long_Integer (Character'Pos (Text (Index))
                                - Character'Pos ('0'));
         Index := Index + 1;
      end loop;

      return (if Signed then -Result else Result);
   end Number_Of;

   --  A number's text as binary64, zero where it is not one.
   function Real_Of (Text : String) return Long_Float is
      Trimmed : constant String := Model_Runner.Text.Trim (Text);
   begin
      if Trimmed'Length = 0 then
         return 0.0;
      end if;
      return Long_Float'Value (Trimmed);
   exception
      when others =>
         return Long_Float (Number_Of (Trimmed));
   end Real_Of;

   --  A binary64 written as Python writes one: the fewest digits that
   --  read back as the same number, a point and at least one digit
   --  after it, and an exponent from 1e16 up and below 1e-4. The
   --  digits come from the C library, which rounds them correctly;
   --  Ada's own image does not go to seventeen.
   function Real_Image (X : Long_Float) return String is
      function Snprintf
        (Buffer : Interfaces.C.Strings.chars_ptr;
         Size   : Interfaces.C.size_t;
         Format : Interfaces.C.Strings.chars_ptr;
         Places : Interfaces.C.int;
         Value  : Interfaces.C.double) return Interfaces.C.int
        with Import, Convention => C_Variadic_3,
             External_Name => "snprintf";

      Room   : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String ([1 .. 64 => ' ']);
      Format : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String ("%.*e");
      Chosen : Ada.Strings.Unbounded.Unbounded_String;
   begin
      if X /= X then
         Interfaces.C.Strings.Free (Room);
         Interfaces.C.Strings.Free (Format);
         return "nan";
      elsif X > Long_Float'Last or else X < Long_Float'First then
         Interfaces.C.Strings.Free (Room);
         Interfaces.C.Strings.Free (Format);
         return (if X > 0.0 then "inf" else "-inf");
      end if;

      for Places in 0 .. 16 loop
         declare
            Written : constant Interfaces.C.int :=
              Snprintf (Room, 64, Format, Interfaces.C.int (Places),
                        Interfaces.C.double (X));
            pragma Unreferenced (Written);
            Said : constant String := Interfaces.C.Strings.Value (Room);
         begin
            Chosen := Ada.Strings.Unbounded.To_Unbounded_String (Said);
            exit when Long_Float'Value (Said) = X;
         end;
      end loop;
      Interfaces.C.Strings.Free (Room);
      Interfaces.C.Strings.Free (Format);

      --  d.ddde[+-]XX, taken apart and put together Python's way.
      declare
         Said     : constant String :=
           Ada.Strings.Unbounded.To_String (Chosen);
         At_E     : constant Natural := Ada.Strings.Fixed.Index (Said, "e");
         Negative : constant Boolean := Said (Said'First) = '-';
         Mantissa : constant String :=
           Said ((if Negative then Said'First + 1 else Said'First)
                 .. At_E - 1);
         Exponent : constant Integer :=
           Integer'Value (Said (At_E + 1 .. Said'Last));
         Digits_Only : constant String :=
           Mantissa (Mantissa'First)
           & (if Mantissa'Length > 2
              then Mantissa (Mantissa'First + 2 .. Mantissa'Last) else "");
         Sign : constant String := (if Negative then "-" else "");
      begin
         if Exponent >= 16 or else Exponent < -4 then
            declare
               Exp_Image : constant String :=
                 Model_Runner.Text.Image (Long_Long_Integer (abs Exponent));
            begin
               return Sign & Mantissa & "e"
                 & (if Exponent < 0 then "-" else "+")
                 & (if Exp_Image'Length < 2 then "0" else "") & Exp_Image;
            end;
         elsif Exponent >= 0 then
            declare
               Whole : constant Natural := Exponent + 1;
            begin
               if Digits_Only'Length <= Whole then
                  return Sign & Digits_Only
                    & String'[1 .. Whole - Digits_Only'Length => '0']
                    & ".0";
               end if;
               return Sign
                 & Digits_Only (Digits_Only'First
                                .. Digits_Only'First + Whole - 1)
                 & "."
                 & Digits_Only (Digits_Only'First + Whole
                                .. Digits_Only'Last);
            end;
         else
            return Sign & "0." & String'[1 .. -Exponent - 1 => '0']
              & Digits_Only;
         end if;
      end;
   end Real_Image;

   --  X to the power Y in binary64, through the C library's pow, which
   --  is what the language calls.
   function Powered (X, Y : Long_Float) return Long_Float is
      function Pow (A, B : Interfaces.C.double) return Interfaces.C.double
        with Import, Convention => C, External_Name => "pow";
   begin
      return Long_Float (Pow (Interfaces.C.double (X),
                              Interfaces.C.double (Y)));
   end Powered;

   --  X rounded to Places decimals, to the nearest and ties to even,
   --  through the C library's formatting, which rounds the exact
   --  binary64 as the language's round does.
   function Rounded (X : Long_Float; Places : Natural) return Long_Float is
      function Snprintf
        (Buffer : Interfaces.C.Strings.chars_ptr;
         Size   : Interfaces.C.size_t;
         Format : Interfaces.C.Strings.chars_ptr;
         Digits_After : Interfaces.C.int;
         Value  : Interfaces.C.double) return Interfaces.C.int
        with Import, Convention => C_Variadic_3,
             External_Name => "snprintf";

      Room   : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String ([1 .. 400 => ' ']);
      Format : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String ("%.*f");
      Written : constant Interfaces.C.int :=
        Snprintf (Room, 400, Format, Interfaces.C.int (Places),
                  Interfaces.C.double (X));
      pragma Unreferenced (Written);
      Said : constant String := Interfaces.C.Strings.Value (Room);
   begin
      Interfaces.C.Strings.Free (Room);
      Interfaces.C.Strings.Free (Format);
      return Real_Of (Said);
   end Rounded;

   --  X with Places digits after the point, as printf's %f writes it.
   function Fixed_Image (X : Long_Float; Places : Natural) return String is
      function Snprintf
        (Buffer : Interfaces.C.Strings.chars_ptr;
         Size   : Interfaces.C.size_t;
         Format : Interfaces.C.Strings.chars_ptr;
         Digits_After : Interfaces.C.int;
         Value  : Interfaces.C.double) return Interfaces.C.int
        with Import, Convention => C_Variadic_3,
             External_Name => "snprintf";

      Room   : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String ([1 .. 400 => ' ']);
      Format : Interfaces.C.Strings.chars_ptr :=
        Interfaces.C.Strings.New_String ("%.*f");
      Written : constant Interfaces.C.int :=
        Snprintf (Room, 400, Format, Interfaces.C.int (Places),
                  Interfaces.C.double (X));
      pragma Unreferenced (Written);
      Said : constant String := Interfaces.C.Strings.Value (Room);
   begin
      Interfaces.C.Strings.Free (Room);
      Interfaces.C.Strings.Free (Format);
      return Said;
   end Fixed_Image;

   --  Whether a sum is worked out in binary64: any term that is not a
   --  whole number, or a true division anywhere in it.
   function Uses_Reals (Value : Operand) return Boolean is
   begin
      for Index in 1 .. Value.Count loop
         if Index > 1 and then Value.Terms (Index).Join = Join_Divide then
            return True;
         end if;
         declare
            Said : constant String := Value_Of (Value.Terms (Index));
         begin
            if Is_Real (Said)
              or else (Index > 1
                       and then Value.Terms (Index).Join = Join_Power
                       and then Number_Of (Said) < 0)
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Uses_Reals;

   function Value_Of (Value : Operand) return String is
      --  Only the filled prefix is ever returned, but defining the whole
      --  buffer costs a kilobyte on a path that is not hot and removes the
      --  question of whether that is really true.
      Result : String (1 .. Max_Comparison) := [others => ' '];
      Filled : Natural := 0;

      Arithmetic : constant Boolean := Is_Sum (Value);
   begin
      --  Text times a whole number is the text that many times over,
      --  "<tok>" * n, as Python repeats a string.
      if Has_Markup (Value) then
         return Markup_Joined (Value);
      end if;

      if Is_Repetition (Value) then
         declare
            Left  : constant Held := Resolve (Value.Terms (1));
            Right : constant Held := Resolve (Value.Terms (2));
         begin
            begin
               declare
                  Piece : constant String :=
                    (if Left.Kind = Value_Text then Text_Of (Left)
                     else Text_Of (Right));
                  Times : constant Long_Long_Integer :=
                    Number_Of (if Left.Kind = Value_Text
                               then Text_Of (Right) else Text_Of (Left));
                  Long  : Ada.Strings.Unbounded.Unbounded_String;
               begin
                  for Unused in 1 .. Times loop
                     Ada.Strings.Unbounded.Append (Long, Piece);
                     exit when Ada.Strings.Unbounded.Length (Long)
                               > Max_Variable_Bytes;
                  end loop;
                  return Ada.Strings.Unbounded.To_String (Long);
               end;
            end;
         end;
      end if;

      --  A sum is evaluated rather than run together, and its answer is
      --  the number's own text: everything downstream of an operand takes
      --  text, and a number written down is still a number.
      --  Products before sums, as the language binds them: a run of
      --  terms joined by the multiplicative joins is worked out as it is
      --  read, and added to or taken from the total where a plus or a
      --  minus ends it. Zero divides nothing, and a division that does
      --  not come out whole is not a whole number, which is the only
      --  kind this engine writes: both refuse where they are read.
      --  In binary64 where any term is not a whole number or a true
      --  division stands anywhere, as the language works it: 7 / 2 is
      --  3.5 and 8 / 2 is 4.0, and 1.5 + 1 is 2.5.
      --  Products before sums and powers before products, as the
      --  language binds them: a factor is raised as it is read, folded
      --  into the product when the next product join comes, and the
      --  product is added to or taken from the total when a plus or a
      --  minus ends it. Zero divides nothing, which refuses where it is
      --  read. In binary64 where any term is not a whole number, a true
      --  division stands anywhere, or a power has a negative exponent,
      --  as the language works it: 7 / 2 is 3.5, 8 / 2 is 4.0, 2 ** -1
      --  is 0.5 and 1.5 + 1 is 2.5.
      if Arithmetic and then Uses_Reals (Value) then
         declare
            Total   : Long_Float := 0.0;
            Product : Long_Float := 1.0;
            Factor  : Long_Float :=
              (if Value.Count = 0 then 0.0
               else Real_Of (Value_Of (Value.Terms (1))));
            Sign    : Join_Kind := Join_Plus;

            procedure Settle is
            begin
               Product := Product * Factor;
               if Sign = Join_Minus then
                  Total := Total - Product;
               else
                  Total := Total + Product;
               end if;
               Product := 1.0;
            end Settle;
         begin
            for Index in 2 .. Value.Count loop
               declare
                  Next : constant Long_Float :=
                    Real_Of (Value_Of (Value.Terms (Index)));
                  Join : constant Join_Kind := Value.Terms (Index).Join;
               begin
                  case Join is
                     when Join_Plus | Join_Minus | Join_Concat =>
                        Settle;
                        Sign := Join;
                        Factor := Next;
                     when Join_Power =>
                        Factor := Powered (Factor, Next);
                     when Join_Times =>
                        Product := Product * Factor;
                        Factor := Next;
                     when Join_Divide | Join_Floor | Join_Modulo =>
                        if Next = 0.0 then
                           Refuse (Value.Terms (Index).Join_At,
                                   Value.Terms (Index).Join_Len,
                                   E.Template_Unsupported_Construct);
                           return "0";
                        end if;
                        Product := Product * Factor;
                        if Join = Join_Divide then
                           Factor := 1.0;
                           Product := Product / Next;
                        elsif Join = Join_Floor then
                           Factor := 1.0;
                           Product := Long_Float'Floor (Product / Next);
                        else
                           Factor := 1.0;
                           Product :=
                             Product - Next * Long_Float'Floor (Product / Next);
                        end if;
                  end case;
               end;
            end loop;
            Settle;
            return Real_Image (Total);
         end;
      end if;

      if Arithmetic then
         declare
            Total   : Long_Long_Integer := 0;
            Product : Long_Long_Integer := 1;
            Factor  : Long_Long_Integer :=
              (if Value.Count = 0 then 0
               else Number_Of (Value_Of (Value.Terms (1))));
            Sign    : Join_Kind := Join_Plus;

            procedure Settle is
            begin
               Product := Product * Factor;
               if Sign = Join_Minus then
                  Total := Total - Product;
               else
                  Total := Total + Product;
               end if;
               Product := 1;
            end Settle;
         begin
            for Index in 2 .. Value.Count loop
               declare
                  Next : constant Long_Long_Integer :=
                    Number_Of (Value_Of (Value.Terms (Index)));
                  Join : constant Join_Kind := Value.Terms (Index).Join;
               begin
                  case Join is
                     when Join_Plus | Join_Minus | Join_Concat =>
                        Settle;
                        Sign := Join;
                        Factor := Next;
                     when Join_Power =>
                        Factor := Factor ** Natural (Next);
                     when Join_Times =>
                        Product := Product * Factor;
                        Factor := Next;
                     when Join_Divide | Join_Floor | Join_Modulo =>
                        if Next = 0 then
                           Refuse (Value.Terms (Index).Join_At,
                                   Value.Terms (Index).Join_Len,
                                   E.Template_Unsupported_Construct);
                           return "0";
                        end if;
                        Product := Product * Factor;
                        Factor := 1;
                        if Join = Join_Modulo then
                           Product := Product mod Next;
                        else
                           --  The language's // rounds towards minus
                           --  infinity, which is what mod pairs with.
                           Product := (Product - (Product mod Next)) / Next;
                        end if;
                  end case;
               end;
            end loop;
            Settle;
            return Model_Runner.Text.Image (Total);
         end;
      end if;

      if Mixes_Text_And_Data (Value) then
         return "";
      end if;

      for Index in 1 .. Value.Count loop
         declare
            Piece : constant String := Value_Of (Value.Terms (Index));
         begin
            if Filled + Piece'Length > Result'Length then
               --  Past the buffer the rest is run together the long
               --  way: a tools header written as one sum of a dozen
               --  literals is longer than a kilobyte.
               declare
                  Long : Ada.Strings.Unbounded.Unbounded_String :=
                    Ada.Strings.Unbounded.To_Unbounded_String
                      (Result (1 .. Filled) & Piece);
               begin
                  for Later in Index + 1 .. Value.Count loop
                     Ada.Strings.Unbounded.Append
                       (Long, Value_Of (Value.Terms (Later)));
                  end loop;
                  return Ada.Strings.Unbounded.To_String (Long);
               end;
            end if;
            Result (Filled + 1 .. Filled + Piece'Length) := Piece;
            Filled := Filled + Piece'Length;
         end;
      end loop;
      return Result (1 .. Filled);
   end Value_Of;

   --  Whether a name has been given a value on the path taken so far.
   --  Asking is not reading: a name the template never assigns is a name
   --  this answers False about, and reading it stays an error.
   function Is_Defined (Value : Operand) return Boolean is
   begin
      if Value.Count /= 1 then
         return False;
      end if;
      case Value.Terms (1).Kind is
         when Term_Variable | Term_Loop_Previous | Term_Loop_Next
            | Term_Message_Calls =>
            return Resolve (Value.Terms (1)).Kind /= Value_Undefined;
         when Term_Unsupported =>
            return False;
         when others =>
            return True;
      end case;
   end Is_Defined;

   --  Whether a name holds none.
   function Is_None (Value : Operand) return Boolean is
   begin
      return Value.Count = 1
        and then ((Value.Terms (1).Kind = Term_Variable
                   and then Resolve (Value.Terms (1)).Kind = Value_None)
                  or else Value.Terms (1).Kind = Term_None);
   end Is_None;

   --  The value of a one-term operand, or text of a longer one.
   function Held_Of (Value : Operand) return Held is

      --  Whether a value is a list written out: data whose JSON is an
      --  array, and not a message's content parts.
      function Is_Array (H : Held) return Boolean is
         Text : constant String := Model_Runner.Text.Trim (Text_Of (H));
      begin
         return H.Kind = Value_Data and then not H.Parts
           and then Text'Length >= 2
           and then Text (Text'First) = '['
           and then Text (Text'Last) = ']';
      end Is_Array;

      --  Lists joined by '+' are one list, the second's elements after
      --  the first's, as the language adds them: what a template that
      --  gathers a message's parts writes, a part at a time, before it
      --  joins them -- "set ns.parts = ns.parts + ['<|image_pad|>']".
      function Joined_Lists return Held is
         Result : Ada.Strings.Unbounded.Unbounded_String;
         Any    : Boolean := False;
      begin
         for Index in 1 .. Value.Count loop
            declare
               Text  : constant String :=
                 Model_Runner.Text.Trim (Text_Of (Resolve (Value.Terms (Index))));
               Inner : constant String :=
                 Model_Runner.Text.Trim
                   (Text (Text'First + 1 .. Text'Last - 1));
            begin
               if Inner'Length > 0 then
                  if Any then
                     Ada.Strings.Unbounded.Append (Result, ", ");
                  end if;
                  Ada.Strings.Unbounded.Append (Result, Inner);
                  Any := True;
               end if;
            end;
         end loop;
         return As_Data ("[" & Ada.Strings.Unbounded.To_String (Result) & "]");
      end Joined_Lists;

      All_Lists : Boolean := Value.Count >= 2;
   begin
      if Value.Count = 1 and then not Is_Sum (Value) then
         return Resolve (Value.Terms (1));
      end if;
      for Index in 1 .. Value.Count loop
         exit when not All_Lists;
         All_Lists :=
           (Index = 1 or else Value.Terms (Index).Join = Join_Plus)
           and then Is_Array (Resolve (Value.Terms (Index)));
      end loop;
      if All_Lists then
         return Joined_Lists;
      end if;
      if Is_Repetition (Value) then
         return As_Text (Value_Of (Value));
      elsif Is_Sum (Value) then
         return As_Number (Value_Of (Value));
      end if;
      return As_Text (Value_Of (Value));
   end Held_Of;

   function Truth_Of (Value : Clause) return Boolean is
      Result : Boolean;
   begin
      if Value.Sub_At /= 0 then
         Result := Truth_Of (Item.Conditions.all (Value.Sub_At));
         return (if Value.Negated then not Result else Result);
      end if;

      case Value.Operator is
         when Compare_None =>
            --  Truth of a bare operand, as the language it is written in
            --  means it: the empty string is false, and so are the two
            --  words a template writes for false and for nothing. A flag
            --  a template sets to false is read back as its own text, and
            --  text that says "false" being true would make every such
            --  flag true for ever.
            Result := Is_Truthy (Held_Of (Value.Left));

         when Compare_Equal | Compare_Not_Equal =>
            --  The same text, and the same kind of thing where both
            --  sides are one: a number and the text of that number are
            --  not equal, as the language has it.
            declare
               Left  : constant String := Value_Of (Value.Left);
               Right : constant String := Value_Of (Value.Right);
               Same  : Boolean := Left = Right;
            begin
               declare
                  L : constant Held := Held_Of (Value.Left);
                  R : constant Held := Held_Of (Value.Right);
               begin
                  if L.Kind in Structured and then R.Kind in Structured
                  then
                     --  A message against what a filter kept of the
                     --  messages, a list against a list: equal where
                     --  they are written alike.
                     Same := Pythonic (Structure_Of (L))
                       = Pythonic (Structure_Of (R));
                  elsif L.Kind = Value_Number and then R.Kind = Value_Number
                  then
                     --  Two numbers are equal as numbers: 1.0 and 1.
                     Same := Real_Of (Text_Of (L)) = Real_Of (Text_Of (R));
                  elsif Same
                    and then (L.Kind = Value_Number) /= (R.Kind = Value_Number)
                    and then L.Kind in Value_Text | Value_Number
                    and then R.Kind in Value_Text | Value_Number
                  then
                     Same := False;
                  end if;
               end;
               Result :=
                 (if Value.Operator = Compare_Equal then Same else not Same);
            end;

         when Compare_Defined =>
            Result := Is_Defined (Value.Left);

         when Compare_Not_Defined =>
            Result := not Is_Defined (Value.Left);

         when Compare_Is_None =>
            Result := Is_None (Value.Left);

         when Compare_Is_Not_None =>
            Result := not Is_None (Value.Left);

         when Compare_In_Text | Compare_Not_In_Text =>
            --  Whether the left side occurs anywhere in the right. The
            --  same word as the test above and a different question, told
            --  apart by what follows it.
            declare
               Needle : constant String := Value_Of (Value.Left);
               Right  : constant Held := Held_Of (Value.Right);
               Held   : constant String :=
                 (if Right.Kind = Value_Data then Text_Of (Right)
                  else Printed (Right));
               Found  : Boolean := False;
            begin
               if Right.Kind = Value_Message then
                  --  A message named by position: the fields it has,
                  --  as "'x' in message" answers them.
                  Found := Needle = "role" or else Needle = "content"
                    or else (Needle = "tool_calls"
                             and then Right.Start in 1 .. Count
                             and then Conv.Call_Count (Messages, Right.Start)
                                      > 0);
               elsif Right.Kind = Value_Data and then Is_JSON_Mapping (Held)
               then
                  --  Whether the mapping has a member of that name.
                  Found := Member_Of (Held, Needle).Kind /= Value_Undefined;
               elsif Right.Kind = Value_JSON then
                  Found := Member_Of (JSON_Text (Right), Needle).Kind
                           /= Value_Undefined;
               elsif Right.Kind = Value_Data and then Is_JSON_List (Held) then
                  --  Whether the left side is one of the list's
                  --  elements, which is the other question this word
                  --  asks.
                  declare
                     Cursor : Natural := Held'First + 1;
                     Piece  : Span;
                     More   : Boolean;
                  begin
                     loop
                        Next_Element (Held, Cursor, Piece, More);
                        exit when not More;
                        if Decoded (Held (Piece.First .. Piece.Last))
                           = Needle
                        then
                           Found := True;
                           exit;
                        end if;
                     end loop;
                  end;
               elsif Needle'Length > 0
                 and then Held'Length >= Needle'Length
               then
                  for Start in
                    Held'First .. Held'Last - Needle'Length + 1
                  loop
                     if Held (Start .. Start + Needle'Length - 1) = Needle
                     then
                        Found := True;
                        exit;
                     end if;
                  end loop;
               end if;
               Result :=
                 (if Value.Operator = Compare_In_Text
                  then Found else not Found);
            end;

         when Compare_Less | Compare_Less_Or_Equal
            | Compare_Greater | Compare_Greater_Or_Equal =>
            declare
               Left_Text  : constant String := Value_Of (Value.Left);
               Right_Text : constant String := Value_Of (Value.Right);
            begin
               if Is_Real (Left_Text) or else Is_Real (Right_Text) then
                  declare
                     Left  : constant Long_Float := Real_Of (Left_Text);
                     Right : constant Long_Float := Real_Of (Right_Text);
                  begin
                     Result :=
                       (case Value.Operator is
                           when Compare_Less          => Left < Right,
                           when Compare_Less_Or_Equal => Left <= Right,
                           when Compare_Greater       => Left > Right,
                           when others                => Left >= Right);
                  end;
               else
                  declare
                     Left  : constant Long_Long_Integer :=
                       Number_Of (Left_Text);
                     Right : constant Long_Long_Integer :=
                       Number_Of (Right_Text);
                  begin
                     Result :=
                       (case Value.Operator is
                           when Compare_Less          => Left < Right,
                           when Compare_Less_Or_Equal => Left <= Right,
                           when Compare_Greater       => Left > Right,
                           when others                => Left >= Right);
                  end;
               end if;
            end;

         when Compare_Is_True | Compare_Is_Not_True
            | Compare_Is_False | Compare_Is_Not_False =>
            declare
               --  By what the value is, where it is a boolean: a name
               --  holding false reads as the empty text, so asking the
               --  text answered "is false" no for false itself -- and a
               --  template's "enable_thinking is false" took the other
               --  branch. A JSON member is the JSON word; anything else
               --  is asked by its text as before.
               V    : constant Held := Held_Of (Value.Left);
               Text : constant String :=
                 (if V.Kind in Value_Boolean | Value_Data then ""
                  else Value_Of (Value.Left));
               Says : constant Boolean :=
                 (case V.Kind is
                     when Value_Boolean => V.Start = 1,
                     when Value_Data    => Text_Of (V) = "true",
                     when Value_Text    => False,
                     when others        => Text = "true");
               Nays : constant Boolean :=
                 (case V.Kind is
                     when Value_Boolean => V.Start = 0,
                     when Value_Data    => Text_Of (V) = "false",
                     when Value_Text    => False,
                     when others        => Text = "false");
            begin
               Result :=
                 (case Value.Operator is
                     when Compare_Is_True      => Says,
                     when Compare_Is_Not_True  => not Says,
                     when Compare_Is_False     => Nays,
                     when others               => not Nays);
            end;

         when Compare_Is_String | Compare_Is_Not_String =>
            --  Text is a string, and so is a JSON string read out of a
            --  mapping; a mapping, a list, a number, a message, none and
            --  a name never assigned are not.
            declare
               V    : constant Held := Held_Of (Value.Left);
               Says : constant Boolean :=
                 V.Kind = Value_Text
                 or else (V.Kind = Value_Data
                          and then Is_JSON_String (Text_Of (V)));
            begin
               Result :=
                 (if Value.Operator = Compare_Is_String
                  then Says else not Says);
            end;

         when Compare_Is_Mapping | Compare_Is_Not_Mapping =>
            declare
               V    : constant Held := Held_Of (Value.Left);
               --  A message and one call are mappings too, as the
               --  conversation's JSON holds them.
               Says : constant Boolean :=
                 (V.Kind = Value_Data
                  and then Is_JSON_Mapping (Text_Of (V)))
                 or else V.Kind in Value_JSON | Value_Message
                 or else (V.Kind = Value_Call and then V.Index /= 0);
            begin
               Result :=
                 (if Value.Operator = Compare_Is_Mapping
                  then Says else not Says);
            end;

         when Compare_Is_Number | Compare_Is_Not_Number =>
            --  A boolean is a number too, as Python counts them.
            declare
               V    : constant Held := Held_Of (Value.Left);
               Says : constant Boolean :=
                 V.Kind in Value_Number | Value_Boolean
                 or else (V.Kind = Value_Data
                          and then Text_Of (V)'Length > 0
                          and then (Text_Of (V) (Text_Of (V)'First)
                                      in '0' .. '9' | '-'
                                    or else Text_Of (V) in "true"
                                                         | "false"));
            begin
               Result :=
                 (if Value.Operator = Compare_Is_Number
                  then Says else not Says);
            end;

         when Compare_Is_Boolean | Compare_Is_Not_Boolean =>
            declare
               V    : constant Held := Held_Of (Value.Left);
               Says : constant Boolean :=
                 V.Kind = Value_Boolean
                 or else (V.Kind = Value_Data
                          and then Text_Of (V) in "true" | "false");
            begin
               Result :=
                 (if Value.Operator = Compare_Is_Boolean
                  then Says else not Says);
            end;

         when Compare_Is_Sequence | Compare_Is_Not_Sequence =>
            declare
               V    : constant Held := Held_Of (Value.Left);
               Says : constant Boolean :=
                 V.Kind in Value_Text | Value_Data | Value_JSON
                           | Value_Tools | Value_List
                 or else (V.Kind = Value_Call and then V.Index = 0);
            begin
               Result :=
                 (if Value.Operator = Compare_Is_Sequence
                  then Says else not Says);
            end;

         when Compare_Is_Undefined | Compare_Is_Not_Undefined =>
            Result :=
              (if Value.Operator = Compare_Is_Undefined
               then not Is_Defined (Value.Left)
               else Is_Defined (Value.Left));

         when Compare_Is_Iterable | Compare_Is_Not_Iterable =>
            --  What can be walked: a list, a mapping, text -- which the
            --  language walks character by character -- the tools, a
            --  list of messages and a turn's calls.
            declare
               V    : constant Held := Held_Of (Value.Left);
               Says : constant Boolean :=
                 V.Kind in Value_Text | Value_Data | Value_JSON
                           | Value_Tools | Value_List
                           --  And what was never set: the language's
                           --  undefined walks as nothing, and says it
                           --  can be walked.
                           | Value_Undefined
                 or else (V.Kind = Value_Call and then V.Index = 0);
            begin
               Result :=
                 (if Value.Operator = Compare_Is_Iterable
                  then Says else not Says);
            end;

         when Compare_In_Message =>
            --  The fields a message has here. Two it always has, and one
            --  it has when it asked for it: a turn that called nothing
            --  does not carry tool_calls, which is the same answer the
            --  implementation these templates were written for gives and
            --  the reason the question is asked at all. Any other field
            --  is one this engine cannot hold, and the honest answer is
            --  that this message does not have it.
            declare
               Field : constant String := Value_Of (Value.Left);
            begin
               Result := Field = "role" or else Field = "content"
                 or else (Field = "tool_calls" and then Asked_Count > 0);
            end;
      end case;

      return (if Value.Negated then not Result else Result);
   end Truth_Of;

   --  Truth of a whole condition: any conjunction being true is enough.
   function Truth_Of (Value : Condition) return Boolean is
      --  Restored rather than cleared: a condition inside a condition --
      --  a parenthesised group -- must leave the outer one still testing.
      Was     : constant Boolean := Testing;
      Answer  : Boolean := False;
   begin
      Testing := True;
      for Group in 1 .. Value.Group_Used loop
         declare
            Span : Conjunction renames Value.Groups (Group);
            All_True : Boolean := Span.Count > 0;
         begin
            for Offset in 0 .. Span.Count - 1 loop
               if not Truth_Of (Value.Clauses (Span.First + Offset)) then
                  All_True := False;
                  exit;
               end if;
            end loop;
            if All_True then
               Answer := True;
               exit;
            end if;
         end;
      end loop;
      Testing := Was;
      return Answer;
   end Truth_Of;

   --  Bind a loop's variable to its element, and its key where the
   --  loop walks a mapping.
   --  Bind a name to one span of a container's JSON: a string as its
   --  decoded text, anything else as the JSON where it lies.
   procedure Bind_Span
     (Where : Natural; Src : String; Value : Span; Base : Natural) is
   begin
      if Is_JSON_String (Src (Value.First .. Value.Last)) then
         Assign_Text (Where, Decoded (Src (Value.First .. Value.Last)));
      elsif Is_JSON_Number (Src (Value.First .. Value.Last)) then
         Assign_Text (Where, Src (Value.First .. Value.Last), Value_Number);
      elsif Src (Value.First .. Value.Last) in "true" | "false" | "null" then
         Store (Where, Read_Out (Src (Value.First .. Value.Last)));
      else
         Slots (Where) :=
           (Kind => Value_Data,
            Offset => Base + Value.First - Src'First,
            Length => Value.Last - Value.First + 1,
            Start => 1);
      end if;
   end Bind_Span;

   procedure Bind_Element (L : in out Loop_State) is
   begin
      case L.Kind is
         when Over_Elements | Over_Entries =>
            declare
               Src    : constant String :=
                 Pool (L.Base + 1 .. L.Base + L.Base_Length);
               Key, Value : Span;
               Found  : Boolean;
               Cursor : Natural := L.Cursor;
            begin
               if L.Kind = Over_Elements then
                  Next_Element (Src, Cursor, Value, Found);
                  if Found and then L.Key /= 0
                    and then Is_JSON_Mapping (Src (Value.First .. Value.Last))
                    and then Member_Of (Src (Value.First .. Value.Last),
                                        "grouper").Kind /= Value_Undefined
                  then
                     --  A group from groupby: the grouper and the list.
                     declare
                        Piece : constant String :=
                          Src (Value.First .. Value.Last);
                     begin
                        Store (L.Var, Member_Of (Piece, "grouper"));
                        Store (L.Key, Member_Of (Piece, "list"));
                     end;
                  elsif Found and then L.Key /= 0
                    and then Is_JSON_List (Src (Value.First .. Value.Last))
                  then
                     --  Two names over a list of pairs take the pair
                     --  apart, as the language unpacks a tuple: what
                     --  dictsort answers is walked this way.
                     declare
                        Inner  : Natural := Value.First + 1;
                        First, Second : Span;
                        Got    : Boolean;
                     begin
                        Next_Element (Src, Inner, First, Got);
                        if Got then
                           Bind_Span (L.Var, Src, First, L.Base);
                           Next_Element (Src, Inner, Second, Got);
                           if Got then
                              Bind_Span (L.Key, Src, Second, L.Base);
                           end if;
                        end if;
                     end;
                  elsif Found then
                     Bind_Span (L.Var, Src, Value, L.Base);
                  end if;
               else
                  --  A mapping walked: the first name is the key, as
                  --  it is in the language whether or not a second
                  --  name is written for the value.
                  Next_Member (Src, Cursor, Key, Value, Found);
                  if Found then
                     Assign_Text
                       (L.Var, Decoded (Src (Key.First .. Key.Last)));
                     if L.Key /= 0 then
                        Bind_Span (L.Key, Src, Value, L.Base);
                     end if;
                  end if;
               end if;
               if Found then
                  L.Cursor := Cursor;
               end if;
            end;
         when Over_Tools =>
            Slots (L.Var) :=
              (Kind => Value_JSON, Start => L.Index, others => <>);
         when Over_Messages =>
            Slots (L.Var) :=
              (Kind => Value_Message, Offset => 0, Length => 0,
               Start => (if L.Reversed then L.To - L.Index + 1
                         else L.From + L.Index - 1));
         when Over_Calls =>
            Slots (L.Var) :=
              (Kind => Value_Call, Offset => L.Message, Length => 0,
               Start => L.Index);
         when others =>
            null;
      end case;
   end Bind_Element;

   --  Start walking whatever the operand is worth, or skip the loop.
   procedure Each_Begin (Step : Instruction) is separate;

   --  Advance the innermost loop, or leave it.
   procedure Each_Next (Step : Instruction) is
   begin
      if Loop_Depth = 0 then
         Position := Position + 1;
         return;
      end if;

      declare
         L : Loop_State renames Loops (Loop_Depth);
      begin
         if L.Index < L.Total and then not Breaking then
            L.Index := L.Index + 1;
            Bind_Element (L);
            Position := Step.Target + 1;
         else
            Breaking := False;
            Slots (L.Var) := (Kind => Value_Undefined, others => <>);
            if L.Key /= 0 then
               Slots (L.Key) := (Kind => Value_Undefined, others => <>);
            end if;
            if L.Kind in Over_Elements | Over_Entries
              and then L.Base + L.Base_Length = Pool_Used
            then
               Pool_Used := L.Base;
            end if;
            Pop_Loop;
            Position := Position + 1;
         end if;
      end;
   end Each_Next;

   procedure Execute is separate;

begin
   Target := [others => ' '];
   Last := 0;
   Status := E.Success;

   if not Item.Ready then
      Status := E.Make (E.Template_Missing);
      return;
   end if;

   --  The name messages starts out meaning the whole conversation. A
   --  template that never assigns anything sees exactly what it did
   --  before this table existed.
   Slots (1) := (Kind => Value_List, Start => 1, others => <>);

   --  A template that sets its own bos_token or eos_token reads the
   --  name as a name from then on; before that, and on the right of
   --  its own assignment -- bos_token or '' -- it holds the model's.
   for Index in 1 .. Item.Name_Used loop
      declare
         Name : constant String :=
           Item.Source.all (Item.Names (Index).Offset + 1
                            .. Item.Names (Index).Offset
                               + Item.Names (Index).Length);
      begin
         if Name = "bos_token" then
            Store (Index, As_Text (Beginning_Token));
         elsif Name = "eos_token" then
            Store (Index, As_Text (End_Token));
         end if;
      end;
   end loop;

   --  And the tools, where the template reads them and the caller
   --  offered some. Left undefined otherwise, which is what makes
   --  "if tools" false for a caller who offered none -- the same answer a
   --  template gets from a build that had never heard of them.
   --  The tools, and none where none were offered: defined either
   --  way, as the reference implementation passes them -- tools=None
   --  -- so a template asking "tools is defined" gets the answer it
   --  was written against, and "if tools", "tools is none" and "tools
   --  is iterable" each say what they say there.
   if Item.Tools_Slot /= 0 then
      Slots (Item.Tools_Slot) :=
        (if Tool_Count > 0 then (Kind => Value_Tools, others => <>)
         else (Kind => Value_None, others => <>));
   end if;

   --  And the name a reasoning model's template asks after, where it asks
   --  and where the caller has an answer. Left undefined otherwise, which
   --  is what the template's own "is defined" is there to find out: a
   --  caller who says nothing leaves the model to do what it was trained
   --  to do.
   --  As the boolean jinja2 is handed, not the word for it: a template
   --  asks "enable_thinking is false", which text never is.
   if Item.Thinking_Slot /= 0 and then Thinking /= Thinking_Unstated then
      Slots (Item.Thinking_Slot) :=
        (Kind   => Value_Boolean,
         Offset => (if Thinking = Thinking_On then 1 else 0),
         others => <>);
   end if;

   --  A flat instruction list with jumps. Rendering recurses in one
   --  place only, a macro call, and that is bounded by the nesting
   --  depth; the iteration bound holds across the whole render, calls
   --  included.
   while Position <= Item.Program_Used loop
      Execute;

      if Exhausted then
         Last := 0;
         Status := E.Make (E.Template_Iteration_Limit);
         E.Add_Integer
           (Status, "limit", Long_Long_Integer (Item.Step_Limit));
         return;
      end if;

      if Refused then
         Last := 0;
         Status := E.Make (Refused_Why);
         if Refused_Why = E.Template_Variables_Too_Large then
            E.Add_Integer
              (Status, "limit",
               Long_Long_Integer (if Refused_Limit /= 0 then Refused_Limit
                                  else Pool'Length),
               E.Param_Bytes);
         end if;
         if Refused_Len > 0 then
            E.Add_Text
              (Status, "construct",
               Item.Source.all
                 (Refused_At + 1 .. Refused_At + Refused_Len),
               E.Param_Identifier);
         end if;
         return;
      end if;

      if Overflow then
         Last := 0;
         Status := E.Make (E.Template_Output_Too_Large);
         E.Add_Integer
           (Status, "limit", Long_Long_Integer (Target'Length),
            E.Param_Bytes);
         return;
      end if;
   end loop;
exception
   when Occurrence : others =>
      Last := 0;
      Status := E.Make (E.Internal_Invariant_Violated);
      E.Add_Frame (Status, "templates.render");
      E.Add_Frame
        (Status, Ada.Exceptions.Exception_Name (Occurrence));
end Render;
