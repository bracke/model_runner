separate (Model_Runner.Templates.Render)
function Method_On (Value : Held; Step : Method_Step) return Held is
begin
   case Step.Kind is
      when Method_None =>
         return Value;

      when Method_Cut_From | Method_Cut_To =>
         --  The conversation from a position on is the conversation
         --  still, begun later: a loop over messages[1:] binds each
         --  turn as itself, its calls included, as one over the
         --  whole list does.
         --  And up to a position, messages[:-1], it is the
         --  conversation ended sooner.
         if Value.Kind = Value_List then
            declare
               Where : constant Long_Long_Integer :=
                 Number_Of
                   (Value_Of (Item.Operands.all (Step.At_Operand)));
               Total : constant Long_Long_Integer :=
                 Long_Long_Integer
                   (Integer'Max (Last_Of (Value) - Value.Start + 1, 0));
               From  : constant Long_Long_Integer :=
                 (if Where < 0
                  then Long_Long_Integer'Max (0, Total + Where)
                  else Long_Long_Integer'Min (Where, Total));
            begin
               if Step.Kind = Method_Cut_From then
                  return (Kind  => Value_List,
                          Start => Value.Start + Natural (From),
                          Index => Value.Index, others => <>);
               end if;
               return (Kind  => Value_List, Start => Value.Start,
                       Index => Value.Start + Natural (From),
                       others => <>);
            end;
         end if;

         --  A cut through a list keeps the elements from or before
         --  the position, counted as the language counts them; a
         --  cut through text is a cut through text.
         if Value.Kind in Value_Tools | Value_List | Value_Call
           or else (Value.Kind = Value_Data
                    and then Is_JSON_List (Text_Of (Value)))
         then
            declare
               Src   : constant String := Listed (Value);
               Spans : Span_Array;
               Count : Natural;
               Where : Long_Long_Integer :=
                 Number_Of (Value_Of (Item.Operands.all (Step.At_Operand)));
               Kept  : Span_Array;
               Held_Count : Natural := 0;
            begin
               Elements_Of (Src, Spans, Count);
               if Where < 0 then
                  Where := Long_Long_Integer'Max
                    (0, Long_Long_Integer (Count) + Where);
               end if;
               for Index in 1 .. Count loop
                  if (Step.Kind = Method_Cut_From
                      and then Long_Long_Integer (Index) > Where)
                    or else (Step.Kind = Method_Cut_To
                             and then Long_Long_Integer (Index) <= Where)
                  then
                     Held_Count := Held_Count + 1;
                     Kept (Held_Count) := Spans (Index);
                  end if;
               end loop;
               return List_Of (Src, Kept, Held_Count);
            end;
         end if;
         return As_Text (Applied (Step, Prompt_Text (Value)));

      when Method_Strip | Method_Left_Strip | Method_Right_Strip
         | Method_Split_First | Method_Split_Last
         | Method_Split_Once_After | Method_Split_Once_Rest =>
         return As_Text (Applied (Step, Prompt_Text (Value)));

      when Method_Split_Whole =>
         --  The pieces as a list, which is what the language
         --  answers, and which a template then counts, indexes and
         --  walks.
         declare
            Text   : constant String := Prompt_Text (Value);
            Marker : constant String :=
              Value_Of (Item.Operands.all (Step.At_Operand));
            R      : Ada.Strings.Unbounded.Unbounded_String;
            From   : Natural := Text'First;
            Index  : Natural := Text'First;
         begin
            Ada.Strings.Unbounded.Append (R, "[");
            if Marker'Length = 0 then
               Ada.Strings.Unbounded.Append (R, Quoted (Text));
            else
               while Index + Marker'Length - 1 <= Text'Last loop
                  if Text (Index .. Index + Marker'Length - 1) = Marker
                  then
                     Ada.Strings.Unbounded.Append
                       (R, Quoted (Text (From .. Index - 1)) & ", ");
                     Index := Index + Marker'Length;
                     From := Index;
                  else
                     Index := Index + 1;
                  end if;
               end loop;
               Ada.Strings.Unbounded.Append
                 (R, Quoted (Text (From .. Text'Last)));
            end if;
            Ada.Strings.Unbounded.Append (R, "]");
            return As_Data (Ada.Strings.Unbounded.To_String (R));
         end;

      when Method_Starts_With | Method_Ends_With =>
         declare
            Text : constant String := Prompt_Text (Value);
            Wanted : constant String :=
              (if Step.At_Operand = 0 then ""
               else Value_Of (Item.Operands.all (Step.At_Operand)));
            Yes : Boolean := False;
         begin
            if Wanted'Length <= Text'Length then
               if Step.Kind = Method_Starts_With then
                  Yes := Text (Text'First .. Text'First + Wanted'Length - 1)
                         = Wanted;
               else
                  Yes := Text (Text'Last - Wanted'Length + 1 .. Text'Last)
                         = Wanted;
               end if;
            end if;
            return (Kind => Value_Boolean, Start => (if Yes then 1 else 0),
                    others => <>);
         end;

      when Method_Index =>
         return Indexed
           (Value, Value_Of (Item.Operands.all (Step.At_Operand)));

      when Method_Member =>
         return Along
           (Value, Value_Of (Item.Operands.all (Step.At_Operand)));

      when Method_Format =>
         declare
            Text  : constant String := Prompt_Text (Value);
            R     : Ada.Strings.Unbounded.Unbounded_String;
            Index : Natural := Text'First;
            Next  : Natural := 0;

            function Argument (Which : Natural) return String
            is (if Which = 0 and then Step.At_Operand /= 0
                then Printed (Held_Of (Item.Operands.all
                                         (Step.At_Operand)))
                elsif Which = 1 and then Step.Second_At /= 0
                then Printed (Held_Of (Item.Operands.all
                                         (Step.Second_At)))
                else "");
         begin
            while Index <= Text'Last loop
               if Index < Text'Last
                 and then Text (Index .. Index + 1) in "{{" | "}}"
               then
                  Ada.Strings.Unbounded.Append (R, Text (Index));
                  Index := Index + 2;
               elsif Index < Text'Last
                 and then Text (Index .. Index + 1) = "{}"
               then
                  Ada.Strings.Unbounded.Append (R, Argument (Next));
                  Next := Next + 1;
                  Index := Index + 2;
               elsif Index + 2 <= Text'Last
                 and then Text (Index) = '{'
                 and then Text (Index + 1) in '0' .. '1'
                 and then Text (Index + 2) = '}'
               then
                  Ada.Strings.Unbounded.Append
                    (R, Argument (Character'Pos (Text (Index + 1))
                                  - Character'Pos ('0')));
                  Index := Index + 3;
               else
                  Ada.Strings.Unbounded.Append (R, Text (Index));
                  Index := Index + 1;
               end if;
            end loop;
            return As_Text (Ada.Strings.Unbounded.To_String (R));
         end;

      when Method_Replace =>
         declare
            Text     : constant String := Prompt_Text (Value);
            Old_Text : constant String :=
              (if Step.At_Operand = 0 then ""
               else Value_Of (Item.Operands.all (Step.At_Operand)));
            New_Text : constant String :=
              (if Step.Second_At = 0 then ""
               else Value_Of (Item.Operands.all (Step.Second_At)));
            R : Ada.Strings.Unbounded.Unbounded_String;
            Index : Natural := Text'First;
         begin
            if Old_Text'Length = 0 then
               return As_Text (Text);
            end if;
            while Index <= Text'Last loop
               if Index + Old_Text'Length - 1 <= Text'Last
                 and then Text (Index .. Index + Old_Text'Length - 1)
                          = Old_Text
               then
                  Ada.Strings.Unbounded.Append (R, New_Text);
                  Index := Index + Old_Text'Length;
               else
                  Ada.Strings.Unbounded.Append (R, Text (Index));
                  Index := Index + 1;
               end if;
            end loop;
            return As_Text (Ada.Strings.Unbounded.To_String (R));
         end;

      when Method_Items =>
         --  The mapping's entries as the language gives them: a list
         --  of pairs, which a loop with two names takes apart and
         --  anything else reads as a list -- so json_spec|items has
         --  no member called type, as a template asking it expects.
         declare
            Src : constant String :=
              (if Value.Kind in Value_JSON | Value_Data
               then JSON_Text (Value) else "");
         begin
            if not Is_JSON_Mapping (Src) then
               return Value;
            end if;
            declare
               Cursor : Natural := Src'First + 1;
               Key, Member : Span;
               Found  : Boolean;
               Pairs  : Ada.Strings.Unbounded.Unbounded_String;
               Any    : Boolean := False;
            begin
               loop
                  Next_Member (Src, Cursor, Key, Member, Found);
                  exit when not Found;
                  Ada.Strings.Unbounded.Append
                    (Pairs,
                     (if Any then ", " else "") & Tuple_Open
                     & Src (Key.First .. Key.Last) & ", "
                     & Src (Member.First .. Member.Last) & "]");
                  Any := True;
               end loop;
               return As_Data
                 ("[" & Ada.Strings.Unbounded.To_String (Pairs) & "]");
            end;
         end;

      when Method_Upper | Method_Lower | Method_Title
         | Method_Capitalize =>
         return As_Text
           (Filtered
              ((Kind => (case Step.Kind is
                            when Method_Upper => Filter_Upper,
                            when Method_Lower => Filter_Lower,
                            when Method_Title => Filter_Title,
                            when others => Filter_Capitalize),
                others => <>),
               Prompt_Text (Value)));

      when Method_Keys | Method_Values =>
         --  The mapping's keys, or its values, as a list.
         declare
            Src    : constant String := JSON_Text (Value);
            R      : Ada.Strings.Unbounded.Unbounded_String;
            Cursor : Natural;
            Key, Member : Span;
            Found  : Boolean;
            Any    : Boolean := False;
         begin
            if not Is_JSON_Mapping (Src) then
               return As_Data ("[]");
            end if;
            Ada.Strings.Unbounded.Append (R, "[");
            Cursor := Src'First + 1;
            loop
               Next_Member (Src, Cursor, Key, Member, Found);
               exit when not Found;
               if Any then
                  Ada.Strings.Unbounded.Append (R, ", ");
               end if;
               Any := True;
               Ada.Strings.Unbounded.Append
                 (R, (if Step.Kind = Method_Keys
                      then Src (Key.First .. Key.Last)
                      else Src (Member.First .. Member.Last)));
            end loop;
            Ada.Strings.Unbounded.Append (R, "]");
            return As_Data (Ada.Strings.Unbounded.To_String (R));
         end;

      when Method_Get =>
         --  One member by name, or the stand-in where there is
         --  none: the one given, or None.
         declare
            Name : constant String :=
              (if Step.At_Operand = 0 then ""
               else Value_Of (Item.Operands.all (Step.At_Operand)));
            R    : constant Held := Along (Value, Name);
         begin
            if R.Kind = Value_Undefined and then Step.Second_At /= 0 then
               return Held_Of (Item.Operands.all (Step.Second_At));
            elsif R.Kind = Value_Undefined then
               --  get answers None for a missing key, which "is
               --  none" finds and "is defined" does not refuse.
               return (Kind => Value_None, others => <>);
            end if;
            return R;
         end;
   end case;
end Method_On;
