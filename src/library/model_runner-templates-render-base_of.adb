separate (Model_Runner.Templates.Render)
function Base_Of (Value : Term) return Held is
begin
   case Value.Kind is
      when Term_Variable =>
         declare
            R : Held := Held_Of (Value.Offset);
         begin
            if Value.Path_Len > 0 then
               R := Along
                 (R, Item.Source.all
                       (Value.Path_At + 1
                        .. Value.Path_At + Value.Path_Len));
            end if;
            if Value.Indexes then
               R := Indexed
                 (R, Value_Of (Item.Operands.all (Value.Index_At)));
            end if;
            if Value.Tail_Len > 0 then
               R := Along
                 (R, Item.Source.all
                       (Value.Tail_At + 1
                        .. Value.Tail_At + Value.Tail_Len));
            end if;
            return R;
         end;

      when Term_List =>
         --  A list written out, made of what its elements are worth:
         --  a number where the element is one by construction or
         --  holds one, a mapping or list as its JSON, text as a JSON
         --  string.
         declare
            R : Ada.Strings.Unbounded.Unbounded_String;
         begin
            Ada.Strings.Unbounded.Append
              (R, (if Value.Offset = 1 then Tuple_Open else "["));
            for Which in 1 .. Value.Length loop
               if Which > 1 then
                  Ada.Strings.Unbounded.Append (R, ", ");
               end if;
               Ada.Strings.Unbounded.Append
                 (R, Encoded (Item.Operands.all (Value.Index_At + Which - 1)));
            end loop;
            Ada.Strings.Unbounded.Append (R, "]");
            return As_Data (Ada.Strings.Unbounded.To_String (R));
         end;

      when Term_Dict =>
         --  A mapping written out: each key as its text, each value
         --  as a list's element is.
         declare
            R : Ada.Strings.Unbounded.Unbounded_String;
         begin
            Ada.Strings.Unbounded.Append (R, "{");
            for Which in 1 .. Value.Length loop
               if Which > 1 then
                  Ada.Strings.Unbounded.Append (R, ", ");
               end if;
               Ada.Strings.Unbounded.Append
                 (R, Quoted (Value_Of
                               (Item.Operands.all
                                  (Value.Index_At + 2 * Which - 2)))
                     & ": "
                     & Encoded (Item.Operands.all
                                  (Value.Index_At + 2 * Which - 1)));
            end loop;
            Ada.Strings.Unbounded.Append (R, "}");
            return As_Data (Ada.Strings.Unbounded.To_String (R));
         end;

      when Term_Loop_Previous | Term_Loop_Next =>
         --  The message beside the bound one in a list loop, or
         --  nothing at either end and outside such a loop.
         declare
            R : Held := Nothing;
            Beside : Natural := 0;
         begin
            if Loop_Depth > 0
              and then Loops (Loop_Depth).Kind = Over_Messages
            then
               declare
                  L : Loop_State renames Loops (Loop_Depth);
                  Here : constant Natural := Slots (L.Var).Start;
               begin
                  if Value.Kind = Term_Loop_Previous then
                     if (not L.Reversed and then Here > L.From)
                       or else (L.Reversed and then Here < L.To)
                     then
                        Beside := (if L.Reversed then Here + 1
                                   else Here - 1);
                     end if;
                  else
                     if (not L.Reversed and then Here < L.To)
                       or else (L.Reversed and then Here > L.From)
                     then
                        Beside := (if L.Reversed then Here - 1
                                   else Here + 1);
                     end if;
                  end if;
               end;
            elsif Loop_Depth > 0
              and then Loops (Loop_Depth).Kind = Legacy_List
            then
               if Value.Kind = Term_Loop_Previous then
                  if Current > Loop_Start then
                     Beside := Current - 1;
                  end if;
               elsif Current < Loop_Stop and then Current > 0 then
                  Beside := Current + 1;
               end if;
            end if;
            if Beside /= 0 then
               R := (Kind => Value_Message, Start => Beside,
                     others => <>);
               if Value.Path_Len > 0 then
                  R := Along
                    (R, Item.Source.all
                          (Value.Path_At + 1
                           .. Value.Path_At + Value.Path_Len));
               end if;
            end if;
            return R;
         end;

      when Term_Call_Arguments =>
         return As_Data (Raw_Of (Value));

      when Term_Message_Calls =>
         if Message_As_Data then
            return Field_Of (Held_Of (Item.Message_Slot), "tool_calls");
         end if;
         return Field_Of
           ((Kind => Value_Message, Start => Bound_Message,
             others => <>), "tool_calls");

      when Term_Group =>
         declare
            Inner : Operand renames Item.Operands.all (Value.Offset);
         begin
            if Inner.Count = 1 and then not Is_Sum (Inner) then
               return Resolve (Inner.Terms (1));
            end if;
            return Held_Of (Inner);
         end;

      when Term_Literal =>
         --  Numeric marks what the term is worth after its filters:
         --  'ab'|length is a number and 'ab' still text.
         if Value.Numeric
           and then (Value.Filtered = 0
                     or else Is_Number_Text (Raw_Of (Value)))
         then
            return As_Number (Raw_Of (Value));
         end if;
         return As_Text (Raw_Of (Value));

      when Term_Loop_Index_Zero | Term_Loop_Index_One
         | Term_Loop_Length | Term_Loop_Rev_Index_Zero
         | Term_Loop_Rev_Index_One =>
         return As_Number (Raw_Of (Value));

      when Term_Loop_First | Term_Loop_Last =>
         return (Kind => Value_Boolean,
                 Start => (if Raw_Of (Value) = "true" then 1 else 0),
                 others => <>);

      when Term_Message_Content =>
         if Message_As_Data then
            return Field_Of (Held_Of (Item.Message_Slot), "content");
         end if;
         return Content_Of (Bound_Message);
      when Term_True =>
         return (Kind => Value_Boolean, Start => 1, others => <>);
      when Term_False =>
         return (Kind => Value_Boolean, Start => 0, others => <>);
      when Term_None =>
         return (Kind => Value_None, others => <>);

      when Term_Condition =>
         return (Kind => Value_Boolean,
                 Start => (if Truth_Of (Item.Conditions.all (Value.Offset))
                           then 1 else 0),
                 others => <>);

      when Term_Or | Term_And =>
         declare
            Left : constant Held :=
              Held_Of (Item.Operands.all (Value.Index_At));
         begin
            if Is_Truthy (Left) = (Value.Kind = Term_Or) then
               return Left;
            end if;
            return Held_Of (Item.Operands.all (Value.Length));
         end;

      when Term_Choice =>
         if Truth_Of (Item.Conditions.all (Value.Offset)) then
            return Held_Of (Item.Operands.all (Value.Index_At));
         elsif Value.Length = 0 then
            return Nothing;
         else
            return Held_Of (Item.Operands.all (Value.Length));
         end if;

      when Term_Unsupported =>
         if Value.Why = E.Template_Unknown_Variable then
            if not Testing then
               Refuse (Value.Offset, Value.Length, Value.Why);
            end if;
            return Nothing;
         end if;
         return As_Text (Raw_Of (Value));

      when others =>
         return As_Text (Raw_Of (Value));
   end case;
end Base_Of;
