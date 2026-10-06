separate (Model_Runner.Templates.Render)
function Filter_On (Value : Held; Step : Filter_Step) return Held is
begin
   case Step.Kind is
      when Filter_None | Filter_Safe =>
         return Value;

      when Filter_String =>
         return As_Text (Printed (Value));

      when Filter_Length =>
         return As_Number (Long_Long_Integer (Length_Of (Value)));

      when Filter_JSON =>
         --  Indented where asked, as Python indents: one element a
         --  line, a nested container opening on the line of its
         --  key, and an empty one staying on one line.
         if Step.Arg1 /= 0 then
            declare
               Width : constant Natural :=
                 Natural'Max
                   (0, Natural (Number_Of
                         (Value_Of (Item.Operands.all (Step.Arg1)))));
            begin
               return As_Text
                 (Indented_JSON (Untupled (JSON_Text (Value)), Width));
            end;
         end if;
         return As_Text (Untupled (JSON_Text (Value)));

      when Filter_Params =>
         return As_Text (Params_Of (JSON_Text (Value)));

      when Filter_Qwen_Params =>
         return As_Text (Params_Of (JSON_Text (Value), Qwen => True));

      when Filter_Qwen_Tool =>
         return As_Text (Qwen_Tool_Of (JSON_Text (Value)));

      when Filter_Default =>
         --  As the language does it: the stand-in for a value never
         --  set, and -- told so by a second argument -- for any value
         --  that is false; the stand-in as what it is, so that
         --  default(false) is false and not the word for it.
         if Value.Kind = Value_Undefined
           or else (Step.Arg2 /= 0
                    and then Is_Truthy
                               (Held_Of (Item.Operands.all (Step.Arg2)))
                    and then not Is_Truthy (Value))
         then
            return Held_Of (Item.Operands.all (Step.Arg1));
         end if;
         return Value;

      when Filter_Min =>
         --  The smallest number in a list.
         declare
            Src    : constant String := JSON_Text (Value);
            Cursor : Natural;
            Piece  : Span;
            Found  : Boolean;
            Least  : Long_Float := 0.0;
            Which  : Span := (1, 0);
            Any    : Boolean := False;
         begin
            if not Is_JSON_List (Src) then
               return As_Text ("");
            end if;
            Cursor := Src'First + 1;
            loop
               Next_Element (Src, Cursor, Piece, Found);
               exit when not Found;
               declare
                  N : constant Long_Float :=
                    Real_Of (Decoded (Src (Piece.First .. Piece.Last)));
               begin
                  if not Any or else N < Least then
                     Least := N;
                     Which := Piece;
                  end if;
                  Any := True;
               end;
            end loop;
            return (if Any then Read_Out (Src (Which.First .. Which.Last))
                    else As_Text (""));
         end;

      when Filter_Int =>
         return As_Number (Number_Of (Printed (Value)));

      when Filter_Float =>
         return As_Number (Real_Image (Real_Of (Printed (Value))));

      when Filter_Round =>
         --  To the precision given, the common way -- to the
         --  nearest, ties to even, as the language's round does --
         --  or up or down where the method says so. Always a number
         --  that is not whole, as the language answers.
         declare
            Places : constant Natural :=
              (if Step.Arg1 = 0 then 0
               else Natural'Max
                      (0, Natural (Number_Of
                            (Value_Of (Item.Operands.all (Step.Arg1))))));
            Method : constant String :=
              (if Step.Arg2 = 0 then "common"
               else Value_Of (Item.Operands.all (Step.Arg2)));
            X      : constant Long_Float := Real_Of (Printed (Value));
            Scale  : constant Long_Float := 10.0 ** Places;
         begin
            if Method = "ceil" then
               return As_Number
                 (Real_Image (Long_Float'Ceiling (X * Scale) / Scale));
            elsif Method = "floor" then
               return As_Number
                 (Real_Image (Long_Float'Floor (X * Scale) / Scale));
            end if;
            --  A whole number stays whole, as the language's round
            --  answers an int with an int.
            if not Is_Real (Printed (Value)) then
               return Value;
            end if;
            return As_Number (Real_Image (Rounded (X, Places)));
         end;

      when Filter_Abs =>
         declare
            Said : constant String := Printed (Value);
         begin
            if Is_Real (Said) then
               return As_Number (Real_Image (abs Real_Of (Said)));
            end if;
            return As_Number (abs Number_Of (Said));
         end;

      when Filter_Sum =>
         --  The elements added up, or one member of each, from the
         --  start given: whole where every one is whole.
         declare
            Src   : constant String := Listed (Value);
            Name  : constant String :=
              (if Step.Arg1 = 0 then ""
               else Value_Of (Item.Operands.all (Step.Arg1)));
            Start : constant String :=
              (if Step.Arg2 = 0 then "0"
               else Value_Of (Item.Operands.all (Step.Arg2)));
            Spans : Span_Array;
            Count : Natural;
            Whole : Long_Long_Integer := Number_Of (Start);
            Real  : Long_Float := Real_Of (Start);
            Reals : Boolean := Is_Real (Start);
         begin
            Elements_Of (Src, Spans, Count);
            for Index in 1 .. Count loop
               declare
                  Each : constant Held :=
                    Read_Out (Src (Spans (Index).First
                                   .. Spans (Index).Last));
                  Said : constant String :=
                    Printed (if Name = "" then Each else Along (Each, Name));
               begin
                  Reals := Reals or else Is_Real (Said);
                  Whole := Whole + Number_Of (Said);
                  Real := Real + Real_Of (Said);
               end;
            end loop;
            return (if Reals then As_Number (Real_Image (Real))
                    else As_Number (Whole));
         end;

      when Filter_Urlencode =>
         --  Text percent-encoded for a URL, as the language quotes
         --  it: letters, digits, '-', '_', '.', '~' and '/' as they
         --  are and every other byte as %XX; a mapping as key=value
         --  pairs joined by '&', with a blank as '+'.
         declare
            Hex : constant String := "0123456789ABCDEF";

            function Quoted_URL
              (Text : String; Blank_Plus : Boolean) return String
            is
               R : Ada.Strings.Unbounded.Unbounded_String;
            begin
               for C of Text loop
                  if C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9'
                          | '-' | '_' | '.' | '~'
                    or else (C = '/' and then not Blank_Plus)
                  then
                     Ada.Strings.Unbounded.Append (R, C);
                  elsif C = ' ' and then Blank_Plus then
                     Ada.Strings.Unbounded.Append (R, '+');
                  else
                     Ada.Strings.Unbounded.Append
                       (R, '%' & Hex (Character'Pos (C) / 16 + 1)
                        & Hex (Character'Pos (C) mod 16 + 1));
                  end if;
               end loop;
               return Ada.Strings.Unbounded.To_String (R);
            end Quoted_URL;
         begin
            if (Value.Kind = Value_Data
                and then Is_JSON_Mapping (Text_Of (Value)))
              or else Value.Kind = Value_JSON
            then
               declare
                  Src    : constant String := JSON_Text (Value);
                  Cursor : Natural := Src'First + 1;
                  Key, Member : Span;
                  Found  : Boolean;
                  R      : Ada.Strings.Unbounded.Unbounded_String;
                  Any    : Boolean := False;
               begin
                  loop
                     Next_Member (Src, Cursor, Key, Member, Found);
                     exit when not Found;
                     if Any then
                        Ada.Strings.Unbounded.Append (R, '&');
                     end if;
                     Any := True;
                     Ada.Strings.Unbounded.Append
                       (R, Quoted_URL (Decoded (Src (Key.First .. Key.Last)),
                                       True)
                        & "="
                        & Quoted_URL
                            (Printed (Read_Out (Src (Member.First
                                                     .. Member.Last))),
                             True));
                  end loop;
                  return As_Text (Ada.Strings.Unbounded.To_String (R));
               end;
            end if;
            return As_Text (Quoted_URL (Printed (Value), False));
         end;

      when Filter_Batch | Filter_Slice =>
         --  A list cut into batches of so many, or into so many
         --  slices as even as they can be with the first ones
         --  longer; a short last one filled where a filler was
         --  given.
         declare
            Src   : constant String := Listed (Value);
            N     : constant Natural :=
              Natural'Max
                (1, Natural (Number_Of
                      (Value_Of (Item.Operands.all (Step.Arg1)))));
            Fill  : constant String :=
              (if Step.Arg2 = 0 then ""
               else JSON_Text (Held_Of (Item.Operands.all (Step.Arg2))));
            Spans : Span_Array;
            Count : Natural;
            R     : Ada.Strings.Unbounded.Unbounded_String;
            At_Element : Natural := 1;
         begin
            Elements_Of (Src, Spans, Count);
            Ada.Strings.Unbounded.Append (R, "[");
            if Step.Kind = Filter_Batch then
               declare
                  Batches : constant Natural := (Count + N - 1) / N;
               begin
                  for B in 1 .. Batches loop
                     if B > 1 then
                        Ada.Strings.Unbounded.Append (R, ", ");
                     end if;
                     Ada.Strings.Unbounded.Append (R, "[");
                     for K in 1 .. N loop
                        if K > 1 then
                           Ada.Strings.Unbounded.Append (R, ", ");
                        end if;
                        if At_Element <= Count then
                           Ada.Strings.Unbounded.Append
                             (R, Src (Spans (At_Element).First
                                      .. Spans (At_Element).Last));
                           At_Element := At_Element + 1;
                        elsif Fill /= "" then
                           Ada.Strings.Unbounded.Append (R, Fill);
                        else
                           --  Nothing to fill with: the batch ends.
                           Ada.Strings.Unbounded.Head
                             (R, Ada.Strings.Unbounded.Length (R) - 2);
                           exit;
                        end if;
                     end loop;
                     Ada.Strings.Unbounded.Append (R, "]");
                  end loop;
               end;
            else
               declare
                  Per    : constant Natural := Count / N;
                  Longer : constant Natural := Count mod N;
               begin
                  for S in 1 .. N loop
                     declare
                        Wanted : constant Natural :=
                          Per + (if S <= Longer then 1 else 0);
                     begin
                        if S > 1 then
                           Ada.Strings.Unbounded.Append (R, ", ");
                        end if;
                        Ada.Strings.Unbounded.Append (R, "[");
                        for K in 1 .. Wanted loop
                           if K > 1 then
                              Ada.Strings.Unbounded.Append (R, ", ");
                           end if;
                           Ada.Strings.Unbounded.Append
                             (R, Src (Spans (At_Element).First
                                      .. Spans (At_Element).Last));
                           At_Element := At_Element + 1;
                        end loop;
                        if Fill /= "" and then Wanted < Per + 1
                          and then Longer > 0
                        then
                           if Wanted > 0 then
                              Ada.Strings.Unbounded.Append (R, ", ");
                           end if;
                           Ada.Strings.Unbounded.Append (R, Fill);
                        end if;
                        Ada.Strings.Unbounded.Append (R, "]");
                     end;
                  end loop;
               end;
            end if;
            Ada.Strings.Unbounded.Append (R, "]");
            return As_Data (Ada.Strings.Unbounded.To_String (R));
         end;

      when Filter_Groupby =>
         --  The elements grouped by one member, in that member's
         --  order, each group an object with the grouper and the
         --  list -- what the language's namedtuple answers to, and
         --  what two names over the result take apart.
         declare
            Src   : constant String := Listed (Value);
            Name  : constant String :=
              Value_Of (Item.Operands.all (Step.Arg1));
            Spans : Span_Array;
            Count : Natural;
            Order : Span_Array;
            R     : Ada.Strings.Unbounded.Unbounded_String;

            function Key_Of (S : Span) return Held
            is (Along (Read_Out (Src (S.First .. S.Last)), Name));
         begin
            Elements_Of (Src, Spans, Count);
            Order := Spans;
            for I in 2 .. Count loop
               declare
                  Moving : constant Span := Order (I);
                  J      : Natural := I;
               begin
                  while J > 1
                    and then Before (Key_Of (Moving), Key_Of (Order (J - 1)),
                                     False)
                  loop
                     Order (J) := Order (J - 1);
                     J := J - 1;
                  end loop;
                  Order (J) := Moving;
               end;
            end loop;
            Ada.Strings.Unbounded.Append (R, "[");
            declare
               I : Natural := 1;
            begin
               while I <= Count loop
                  declare
                     Grouper : constant Held := Key_Of (Order (I));
                     Said    : constant String := Printed (Grouper);
                  begin
                     if I > 1 then
                        Ada.Strings.Unbounded.Append (R, ", ");
                     end if;
                     Ada.Strings.Unbounded.Append
                       (R, "{""grouper"": "
                        & (if Grouper.Kind = Value_Undefined then "null"
                           else JSON_Text (Grouper))
                        & ", ""list"": [");
                     declare
                        First_In : Boolean := True;
                     begin
                        while I <= Count
                          and then Printed (Key_Of (Order (I))) = Said
                        loop
                           if not First_In then
                              Ada.Strings.Unbounded.Append (R, ", ");
                           end if;
                           First_In := False;
                           Ada.Strings.Unbounded.Append
                             (R, Src (Order (I).First .. Order (I).Last));
                           I := I + 1;
                        end loop;
                     end;
                     Ada.Strings.Unbounded.Append (R, "]}");
                  end;
               end loop;
            end;
            Ada.Strings.Unbounded.Append (R, "]");
            return As_Data (Ada.Strings.Unbounded.To_String (R));
         end;

      when Filter_Attr =>
         --  An attribute and never an item, as the language has it:
         --  every value here is a mapping, whose members are items,
         --  so the answer is nothing, which is the answer jinja2
         --  gives for a message's role asked for this way.
         return Nothing;

      when Filter_Wordwrap =>
         --  Each line of the text wrapped at the width, words kept
         --  whole unless one is longer than the width and breaking
         --  it was not refused, the lines joined by the wrapstring.
         declare
            T     : constant String := Printed (Value);
            Width : constant Natural :=
              (if Step.Arg1 = 0 then 79
               else Natural'Max
                      (1, Natural (Number_Of
                            (Value_Of (Item.Operands.all (Step.Arg1))))));
            Break_Long : constant Boolean :=
              Step.Arg2 = 0
              or else Is_Truthy (Held_Of (Item.Operands.all (Step.Arg2)));
            Joiner : constant String :=
              (if Step.Arg3 = 0 then "" & ASCII.LF
               else Value_Of (Item.Operands.all (Step.Arg3)));
            R      : Ada.Strings.Unbounded.Unbounded_String;
            Line   : Ada.Strings.Unbounded.Unbounded_String;
            First_Line : Boolean := True;

            procedure End_Line is
            begin
               if not First_Line then
                  Ada.Strings.Unbounded.Append (R, Joiner);
               end if;
               First_Line := False;
               Ada.Strings.Unbounded.Append (R, Line);
               Line := Ada.Strings.Unbounded.Null_Unbounded_String;
            end End_Line;

            procedure Add_Word (Word : String) is
               At_Word : Natural := Word'First;
            begin
               while At_Word <= Word'Last loop
                  declare
                     Have : constant Natural :=
                       Ada.Strings.Unbounded.Length (Line);
                     Rest : constant String := Word (At_Word .. Word'Last);
                  begin
                     if Have = 0 then
                        if Rest'Length <= Width or else not Break_Long then
                           Ada.Strings.Unbounded.Append (Line, Rest);
                           At_Word := Word'Last + 1;
                        else
                           Ada.Strings.Unbounded.Append
                             (Line, Rest (Rest'First .. Rest'First + Width - 1));
                           At_Word := At_Word + Width;
                           End_Line;
                        end if;
                     elsif Have + 1 + Rest'Length <= Width then
                        Ada.Strings.Unbounded.Append (Line, ' ' & Rest);
                        At_Word := Word'Last + 1;
                     else
                        End_Line;
                     end if;
                  end;
               end loop;
            end Add_Word;

            procedure Wrap_Line (Text : String) is
               I : Natural := Text'First;
            begin
               while I <= Text'Last loop
                  if Text (I) in ' ' | ASCII.HT then
                     I := I + 1;
                  else
                     declare
                        J : Natural := I;
                     begin
                        while J <= Text'Last
                          and then Text (J) not in ' ' | ASCII.HT
                        loop
                           J := J + 1;
                        end loop;
                        Add_Word (Text (I .. J - 1));
                        I := J;
                     end;
                  end if;
               end loop;
               End_Line;
            end Wrap_Line;

            From : Natural := T'First;
         begin
            for I in T'Range loop
               if T (I) = ASCII.LF then
                  Wrap_Line (T (From .. I - 1));
                  From := I + 1;
               end if;
            end loop;
            Wrap_Line (T (From .. T'Last));
            return As_Text (Ada.Strings.Unbounded.To_String (R));
         end;

      when Filter_Truncate =>
         --  Cut to the length with the ending in it, at a blank
         --  unless words may be killed, and left alone within the
         --  leeway, as the language cuts.
         declare
            T      : constant String := Printed (Value);
            Length : constant Natural :=
              (if Step.Arg1 = 0 then 255
               else Natural'Max
                      (0, Natural (Number_Of
                            (Value_Of (Item.Operands.all (Step.Arg1))))));
            Kill   : constant Boolean :=
              Step.Arg2 /= 0
              and then Is_Truthy (Held_Of (Item.Operands.all (Step.Arg2)));
            Ending : constant String :=
              (if Step.Arg3 = 0 then "..."
               else Value_Of (Item.Operands.all (Step.Arg3)));
            Leeway : constant Natural := 5;
            Keep_To : constant Integer := Length - Ending'Length;
         begin
            if T'Length <= Length + Leeway or else Keep_To <= 0 then
               return As_Text (if Keep_To <= 0 then Ending else T);
            end if;
            if Kill then
               return As_Text
                 (T (T'First .. T'First + Keep_To - 1) & Ending);
            end if;
            declare
               Cut  : constant String := T (T'First .. T'First + Keep_To - 1);
               Last : Natural := Cut'Last;
            begin
               while Last >= Cut'First and then Cut (Last) /= ' ' loop
                  Last := Last - 1;
               end loop;
               if Last < Cut'First then
                  return As_Text (Cut & Ending);
               end if;
               return As_Text (Cut (Cut'First .. Last - 1) & Ending);
            end;
         end;

      when Filter_Center =>
         --  Centred in the width, the odd blank going left where
         --  the width is odd, as Python centres.
         declare
            T     : constant String := Printed (Value);
            Width : constant Natural :=
              (if Step.Arg1 = 0 then 80
               else Natural'Max
                      (0, Natural (Number_Of
                            (Value_Of (Item.Operands.all (Step.Arg1))))));
         begin
            if T'Length >= Width then
               return As_Text (T);
            end if;
            declare
               Pad   : constant Natural := Width - T'Length;
               Left  : constant Natural :=
                 Pad / 2 + (if Pad mod 2 = 1 and then Width mod 2 = 1
                            then 1 else 0);
               Right : constant Natural := Pad - Left;
            begin
               return As_Text
                 (String'[1 .. Left => ' '] & T & String'[1 .. Right => ' ']);
            end;
         end;

      when Filter_Format =>
         --  printf's %s, %d, %i, %f with a precision, and %%, each
         --  taking the next argument.
         declare
            T    : constant String := Printed (Value);
            R    : Ada.Strings.Unbounded.Unbounded_String;
            Next : Natural := 1;
            I    : Natural := T'First;

            function Argument return String is
               At_Slot : constant Natural :=
                 (case Next is
                     when 1 => Step.Arg1,
                     when 2 => Step.Arg2,
                     when others => Step.Arg3);
            begin
               Next := Next + 1;
               return (if At_Slot = 0 then ""
                       else Value_Of (Item.Operands.all (At_Slot)));
            end Argument;
         begin
            while I <= T'Last loop
               if T (I) = '%' and then I < T'Last then
                  declare
                     J : Natural := I + 1;
                     Places : Integer := -1;
                  begin
                     if T (J) = '.' then
                        J := J + 1;
                        Places := 0;
                        while J <= T'Last and then T (J) in '0' .. '9' loop
                           Places := Places * 10
                             + Character'Pos (T (J)) - Character'Pos ('0');
                           J := J + 1;
                        end loop;
                     end if;
                     if J > T'Last then
                        Ada.Strings.Unbounded.Append (R, T (I .. T'Last));
                        exit;
                     end if;
                     case T (J) is
                        when '%' =>
                           Ada.Strings.Unbounded.Append (R, '%');
                        when 's' =>
                           Ada.Strings.Unbounded.Append (R, Argument);
                        when 'd' | 'i' =>
                           Ada.Strings.Unbounded.Append
                             (R, Model_Runner.Text.Image
                                   (Number_Of (Argument)));
                        when 'f' =>
                           Ada.Strings.Unbounded.Append
                             (R, Fixed_Image
                                   (Real_Of (Argument),
                                    (if Places < 0 then 6 else Places)));
                        when others =>
                           Ada.Strings.Unbounded.Append (R, T (I .. J));
                     end case;
                     I := J + 1;
                  end;
               else
                  Ada.Strings.Unbounded.Append (R, T (I));
                  I := I + 1;
               end if;
            end loop;
            return As_Text (Ada.Strings.Unbounded.To_String (R));
         end;

      when Filter_Striptags =>
         --  Tags taken out and the blanks left run together.
         declare
            T      : constant String := Printed (Value);
            R      : Ada.Strings.Unbounded.Unbounded_String;
            In_Tag : Boolean := False;
            Blank  : Boolean := True;
         begin
            for C of T loop
               if In_Tag then
                  In_Tag := C /= '>';
               elsif C = '<' then
                  In_Tag := True;
               elsif C in ' ' | ASCII.HT | ASCII.LF | ASCII.CR then
                  if not Blank then
                     Ada.Strings.Unbounded.Append (R, ' ');
                  end if;
                  Blank := True;
               else
                  Ada.Strings.Unbounded.Append (R, C);
                  Blank := False;
               end if;
            end loop;
            return As_Text
              (Model_Runner.Text.Trim
                 (Ada.Strings.Unbounded.To_String (R)));
         end;

      when Filter_Pprint =>
         --  As Python prints the value: text in quotes, the rest as
         --  it prints already.
         if Value.Kind = Value_Text then
            declare
               T : constant String := Text_Of (Value);
               Q : constant Character :=
                 (if (for some C of T => C = ''')
                    and then (for all C of T => C /= '"')
                  then '"' else ''');
               R : Ada.Strings.Unbounded.Unbounded_String;
            begin
               Ada.Strings.Unbounded.Append (R, Q);
               for C of T loop
                  if C = '\' or else C = Q then
                     Ada.Strings.Unbounded.Append (R, '\' & C);
                  elsif C = ASCII.LF then
                     Ada.Strings.Unbounded.Append (R, "\n");
                  else
                     Ada.Strings.Unbounded.Append (R, C);
                  end if;
               end loop;
               Ada.Strings.Unbounded.Append (R, Q);
               return As_Text (Ada.Strings.Unbounded.To_String (R));
            end;
         end if;
         return As_Text (Printed (Value));

      when Filter_Random =>
         --  One element, chosen by the clock: a render with this in
         --  it is not the same twice, which is what the filter is.
         declare
            Src   : constant String := Listed (Value);
            Spans : Span_Array;
            Count : Natural;
         begin
            Elements_Of (Src, Spans, Count);
            if Count = 0 then
               return Nothing;
            end if;
            declare
               Seconds : constant Duration :=
                 Ada.Calendar.Seconds (Ada.Calendar.Clock);
               Pick    : constant Natural :=
                 Natural (Long_Float'Floor
                            (Long_Float (Seconds) * 1000.0))
                 mod Count + 1;
            begin
               return Read_Out
                 (Src (Spans (Pick).First .. Spans (Pick).Last));
            end;
         end;

      when Filter_Reverse =>
         --  A list back to front, or text character by character.
         if Value.Kind in Value_Data | Value_Tools | Value_List
                          | Value_Call
           and then (Value.Kind /= Value_Data
                     or else Is_JSON_List (Text_Of (Value)))
         then
            declare
               Src   : constant String := Listed (Value);
               Spans : Span_Array;
               Count : Natural;
               Back  : Span_Array;
            begin
               Elements_Of (Src, Spans, Count);
               for I in 1 .. Count loop
                  Back (I) := Spans (Count - I + 1);
               end loop;
               return List_Of (Src, Back, Count);
            end;
         end if;
         declare
            package Coding renames
              Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
            Wide : constant Wide_Wide_String :=
              Coding.Decode (Printed (Value));
            Back : Wide_Wide_String (Wide'Range);
         begin
            for I in Wide'Range loop
               Back (I) := Wide (Wide'Last - (I - Wide'First));
            end loop;
            return As_Text (Coding.Encode (Back));
         exception
            when others =>
               return Value;
         end;

      when Filter_Max =>
         --  The largest element, or the one whose member is, the
         --  numbers as numbers and the rest as text.
         declare
            Src   : constant String := Listed (Value);
            Name  : constant String :=
              (if Step.Arg3 = 0 then ""
               else Value_Of (Item.Operands.all (Step.Arg3)));
            Spans : Span_Array;
            Count : Natural;
            Best  : Natural := 0;

            function Key_Of (S : Span) return Held
            is (if Name = ""
                then Read_Out (Src (S.First .. S.Last))
                else Along (Read_Out (Src (S.First .. S.Last)), Name));
         begin
            Elements_Of (Src, Spans, Count);
            for I in 1 .. Count loop
               if Best = 0
                 or else Before (Key_Of (Spans (Best)), Key_Of (Spans (I)),
                                 True)
               then
                  Best := I;
               end if;
            end loop;
            if Best = 0 then
               return Nothing;
            end if;
            return Read_Out (Src (Spans (Best).First .. Spans (Best).Last));
         end;

      when Filter_First =>
         return Element_At
           ((if Value.Kind in Value_Tools | Value_List | Value_Call
             then As_Data (Listed (Value)) else Value), 0);

      when Filter_Last =>
         return Element_At
           ((if Value.Kind in Value_Tools | Value_List | Value_Call
             then As_Data (Listed (Value)) else Value), -1);

      when Filter_List =>
         --  A list as it is; a mapping's keys; text as its characters.
         if Value.Kind = Value_Data and then Is_JSON_List (Text_Of (Value))
         then
            return Value;
         elsif Value.Kind in Value_Tools | Value_List | Value_Call then
            return As_Data (Listed (Value));
         elsif Value.Kind in Value_Data | Value_JSON
           and then Is_JSON_Mapping (JSON_Text (Value))
         then
            return Method_On
              (Value, (Kind => Method_Keys, At_Operand => 0,
                       Second_At => 0));
         else
            declare
               T : constant String := Printed (Value);
               R : Ada.Strings.Unbounded.Unbounded_String;
            begin
               Ada.Strings.Unbounded.Append (R, "[");
               for Index in T'Range loop
                  if Index > T'First then
                     Ada.Strings.Unbounded.Append (R, ", ");
                  end if;
                  Ada.Strings.Unbounded.Append
                    (R, Quoted (T (Index .. Index)));
               end loop;
               Ada.Strings.Unbounded.Append (R, "]");
               return As_Data (Ada.Strings.Unbounded.To_String (R));
            end;
         end if;

      when Filter_Join =>
         --  The elements run together with the separator between
         --  them, each printed as it would be on its own, or one
         --  member of each where a member is named.
         declare
            Src   : constant String := Listed (Value);
            Sep   : constant String :=
              (if Step.Arg1 = 0 then ""
               else Value_Of (Item.Operands.all (Step.Arg1)));
            Name  : constant String :=
              (if Step.Arg2 = 0 then ""
               else Value_Of (Item.Operands.all (Step.Arg2)));
            Spans : Span_Array;
            Count : Natural;
            R     : Ada.Strings.Unbounded.Unbounded_String;
         begin
            if Value.Kind = Value_Text then
               return Value;
            end if;
            Elements_Of (Src, Spans, Count);
            for Index in 1 .. Count loop
               if Index > 1 then
                  Ada.Strings.Unbounded.Append (R, Sep);
               end if;
               declare
                  Each : constant Held :=
                    Read_Out (Src (Spans (Index).First
                                   .. Spans (Index).Last));
               begin
                  Ada.Strings.Unbounded.Append
                    (R, Printed (if Name = "" then Each
                                 else Along (Each, Name)));
               end;
            end loop;
            return As_Text (Ada.Strings.Unbounded.To_String (R));
         end;

      when Filter_Map =>
         --  One member of each element, as a list.
         declare
            Src   : constant String := Listed (Value);
            Name  : constant String :=
              (if Step.Arg1 = 0 then ""
               else Value_Of (Item.Operands.all (Step.Arg1)));
            Spans : Span_Array;
            Count : Natural;
            R     : Ada.Strings.Unbounded.Unbounded_String;
         begin
            Elements_Of (Src, Spans, Count);
            Ada.Strings.Unbounded.Append (R, "[");
            for Index in 1 .. Count loop
               if Index > 1 then
                  Ada.Strings.Unbounded.Append (R, ", ");
               end if;
               declare
                  Member : constant Held :=
                    Along (Read_Out (Src (Spans (Index).First
                                          .. Spans (Index).Last)),
                           Name);
               begin
                  Ada.Strings.Unbounded.Append
                    (R, (if Member.Kind = Value_Undefined then "null"
                         else JSON_Text (Member)));
               end;
            end loop;
            Ada.Strings.Unbounded.Append (R, "]");
            return As_Data (Ada.Strings.Unbounded.To_String (R));
         end;

      when Filter_Select | Filter_Reject
         | Filter_Select_Attr | Filter_Reject_Attr =>
         --  The elements that pass the test, or fail it: the element
         --  itself, or the member named first.
         declare
            By_Member : constant Boolean :=
              Step.Kind in Filter_Select_Attr | Filter_Reject_Attr;
            Keeping   : constant Boolean :=
              Step.Kind in Filter_Select | Filter_Select_Attr;
            Src   : constant String := Listed (Value);
            Name  : constant String :=
              (if By_Member and then Step.Arg1 /= 0
               then Value_Of (Item.Operands.all (Step.Arg1)) else "");
            Test_At : constant Natural :=
              (if By_Member then Step.Arg2 else Step.Arg1);
            Arg_At  : constant Natural :=
              (if By_Member then Step.Arg3 else Step.Arg2);
            Test  : constant String :=
              (if Test_At = 0 then ""
               else Value_Of (Item.Operands.all (Test_At)));
            Spans : Span_Array;
            Count : Natural;
            Kept  : Span_Array;
            Held_Count : Natural := 0;
         begin
            Elements_Of (Src, Spans, Count);
            for Index in 1 .. Count loop
               declare
                  Each : constant Held :=
                    Read_Out (Src (Spans (Index).First
                                   .. Spans (Index).Last));
                  Asked : constant Held :=
                    (if By_Member then Along (Each, Name) else Each);
               begin
                  if Passes (Asked, Test, Arg_At) = Keeping then
                     Held_Count := Held_Count + 1;
                     Kept (Held_Count) := Spans (Index);
                  end if;
               end;
            end loop;
            return List_Of (Src, Kept, Held_Count);
         end;

      when Filter_Sort =>
         --  The list in order, by each element or by a member of
         --  it, reversed where asked. Insertion, the lists here
         --  being schemas and short.
         declare
            Src     : constant String := Listed (Value);
            Reverse_Order : constant Boolean :=
              Step.Arg1 /= 0
              and then Is_Truthy (Held_Of (Item.Operands.all (Step.Arg1)));
            Fold    : constant Boolean :=
              Step.Arg2 = 0
              or else not Is_Truthy (Held_Of (Item.Operands.all (Step.Arg2)));
            Name    : constant String :=
              (if Step.Arg3 = 0 then ""
               else Value_Of (Item.Operands.all (Step.Arg3)));
            Spans   : Span_Array;
            Count   : Natural;

            function Key_Of (S : Span) return Held
            is (if Name = ""
                then Read_Out (Src (S.First .. S.Last))
                else Along (Read_Out (Src (S.First .. S.Last)), Name));
         begin
            Elements_Of (Src, Spans, Count);
            for I in 2 .. Count loop
               declare
                  Moving : constant Span := Spans (I);
                  J      : Natural := I;
               begin
                  while J > 1
                    and then (if Reverse_Order
                              then Before (Key_Of (Spans (J - 1)),
                                           Key_Of (Moving), Fold)
                              else Before (Key_Of (Moving),
                                           Key_Of (Spans (J - 1)), Fold))
                  loop
                     Spans (J) := Spans (J - 1);
                     J := J - 1;
                  end loop;
                  Spans (J) := Moving;
               end;
            end loop;
            return List_Of (Src, Spans, Count);
         end;

      when Filter_Dict_Sort =>
         --  A mapping as a list of [key, value] pairs, in key order
         --  -- or value order where asked -- reversed where asked.
         declare
            Src   : constant String := Listed (Value);
            Fold  : constant Boolean :=
              Step.Arg1 = 0
              or else not Is_Truthy (Held_Of (Item.Operands.all (Step.Arg1)));
            By_Value : constant Boolean :=
              Step.Arg2 /= 0
              and then Value_Of (Item.Operands.all (Step.Arg2)) = "value";
            Reverse_Order : constant Boolean :=
              Step.Arg3 /= 0
              and then Is_Truthy (Held_Of (Item.Operands.all (Step.Arg3)));
            Keys, Members : Span_Array;
            Count  : Natural := 0;
            Cursor : Natural;
            Key, Member : Span;
            Found  : Boolean;
            R      : Ada.Strings.Unbounded.Unbounded_String;

            function Key_Of (K, M : Span) return Held
            is (if By_Value
                then Read_Out (Src (M.First .. M.Last))
                else As_Text (Decoded (Src (K.First .. K.Last))));

            function Key_Of (I : Natural) return Held
            is (Key_Of (Keys (I), Members (I)));
         begin
            if not Is_JSON_Mapping (Src) then
               return As_Data ("[]");
            end if;
            Cursor := Src'First + 1;
            loop
               Next_Member (Src, Cursor, Key, Member, Found);
               exit when not Found or else Count >= Max_Elements;
               Count := Count + 1;
               Keys (Count) := Key;
               Members (Count) := Member;
            end loop;
            for I in 2 .. Count loop
               declare
                  K : constant Span := Keys (I);
                  M : constant Span := Members (I);
                  --  The moving pair's key, read before the shift
                  --  writes over its place.
                  Moving : constant Held := Key_Of (K, M);
                  J : Natural := I;
               begin
                  while J > 1
                    and then (if Reverse_Order
                              then Before (Key_Of (J - 1), Moving, Fold)
                              else Before (Moving, Key_Of (J - 1), Fold))
                  loop
                     Keys (J) := Keys (J - 1);
                     Members (J) := Members (J - 1);
                     J := J - 1;
                  end loop;
                  Keys (J) := K;
                  Members (J) := M;
               end;
            end loop;
            Ada.Strings.Unbounded.Append (R, "[");
            for I in 1 .. Count loop
               if I > 1 then
                  Ada.Strings.Unbounded.Append (R, ", ");
               end if;
               Ada.Strings.Unbounded.Append
                 (R, Tuple_Open & Src (Keys (I).First .. Keys (I).Last)
                  & ", "
                  & Src (Members (I).First .. Members (I).Last) & "]");
            end loop;
            Ada.Strings.Unbounded.Append (R, "]");
            return As_Data (Ada.Strings.Unbounded.To_String (R));
         end;

      when Filter_Indent =>
         --  Every line after the first indented by the width, the
         --  first too where asked, blank lines left alone unless
         --  asked.
         declare
            T     : constant String := Printed (Value);
            Width : constant Natural :=
              (if Step.Arg1 = 0 then 4
               else Natural'Max
                      (0, Natural (Number_Of
                            (Value_Of (Item.Operands.all (Step.Arg1))))));
            First : constant Boolean :=
              Step.Arg2 /= 0
              and then Is_Truthy (Held_Of (Item.Operands.all (Step.Arg2)));
            Blank : constant Boolean :=
              Step.Arg3 /= 0
              and then Is_Truthy (Held_Of (Item.Operands.all (Step.Arg3)));
            Pad   : constant String (1 .. Width) := [others => ' '];
            R     : Ada.Strings.Unbounded.Unbounded_String;
            At_Line_Start : Boolean := True;
            Line_Number   : Natural := 1;

            function Line_Is_Blank (From : Natural) return Boolean is
               I : Natural := From;
            begin
               while I <= T'Last and then T (I) /= ASCII.LF loop
                  if T (I) /= ' ' and then T (I) /= ASCII.HT then
                     return False;
                  end if;
                  I := I + 1;
               end loop;
               return True;
            end Line_Is_Blank;
         begin
            for I in T'Range loop
               if At_Line_Start then
                  if (Line_Number > 1 or else First)
                    and then (Blank or else not Line_Is_Blank (I))
                  then
                     Ada.Strings.Unbounded.Append (R, Pad);
                  end if;
                  At_Line_Start := False;
               end if;
               Ada.Strings.Unbounded.Append (R, T (I));
               if T (I) = ASCII.LF then
                  At_Line_Start := True;
                  Line_Number := Line_Number + 1;
               end if;
            end loop;
            return As_Text (Ada.Strings.Unbounded.To_String (R));
         end;

      when Filter_Unique =>
         --  The elements with every repeat after the first dropped.
         declare
            Src   : constant String := Listed (Value);
            Spans : Span_Array;
            Count : Natural;
            Kept  : Span_Array;
            Held_Count : Natural := 0;
         begin
            Elements_Of (Src, Spans, Count);
            for I in 1 .. Count loop
               declare
                  Seen : Boolean := False;
               begin
                  for J in 1 .. Held_Count loop
                     if Src (Spans (I).First .. Spans (I).Last)
                        = Src (Kept (J).First .. Kept (J).Last)
                     then
                        Seen := True;
                        exit;
                     end if;
                  end loop;
                  if not Seen then
                     Held_Count := Held_Count + 1;
                     Kept (Held_Count) := Spans (I);
                  end if;
               end;
            end loop;
            return List_Of (Src, Kept, Held_Count);
         end;

      when Filter_Trim | Filter_Lower | Filter_Upper
         | Filter_Capitalize | Filter_Title | Filter_Replace =>
         --  A text filter reads its content as prompt text, so a
         --  picture given as parts keeps its marker rather than being
         --  trimmed or recased away with the parts' JSON -- which is
         --  what MiniCPM-V 2.5's `content | trim` needs. See
         --  Prompt_Text; a string method reads the same way.
         return As_Text (Filtered (Step, Prompt_Text (Value)));
   end case;
end Filter_On;
