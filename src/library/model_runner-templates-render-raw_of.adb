separate (Model_Runner.Templates.Render)
function Raw_Of (Value : Term) return String is
begin
   case Value.Kind is
      when Term_Literal =>
         return Item.Source.all
           (Value.Offset + 1 .. Value.Offset + Value.Length);
      when Term_Beginning_Token =>
         return Beginning_Token;
      when Term_End_Token =>
         return End_Token;
      when Term_Message_Role | Term_Message_Content =>
         declare
            At_Message : constant Natural := Bound_Message;
         begin
            --  The name holding a message written out as a mapping
            --  -- what a loop over messages[1:] binds it to -- is
            --  read as the mapping it holds.
            if Message_As_Data then
               return Printed
                 (Field_Of (Held_Of (Item.Message_Slot),
                            (if Value.Kind = Term_Message_Role
                             then "role" else "content")));
            end if;

            if At_Message = 0 or else At_Message > Count then
               return "";
            elsif Value.Kind = Term_Message_Role then
               return Conv.Role_Name
                 (Conv.Sender_At (Messages, At_Message));
            else
               return Conv.Content_At (Messages, At_Message);
            end if;
         end;

      when Term_Message_Calls =>
         --  A list of calls has no text. Asked about in a condition
         --  the answer is whether the turn asked for any, which is
         --  what "if message.tool_calls" is written to find out;
         --  asked for as text it is a template printing a list, and
         --  there is no spelling of one this engine may choose.
         if Testing then
            if Message_As_Data then
               return
                 (if Is_Truthy
                       (Field_Of (Held_Of (Item.Message_Slot),
                                  "tool_calls"))
                  then "true" else "");
            end if;
            return (if Asked_Count > 0 then "true" else "");
         end if;

         Refuse (Value.Offset, Value.Length,
                 E.Template_Unsupported_Construct);
         return "";

      when Term_Call_Name | Term_Call_Arguments =>
         --  Which call the name tool_call stands for, and which turn
         --  it belongs to. Both come from the binding where there is
         --  one, and from the running loop otherwise, for the reason
         --  a message's fields do. A field asked for where no call is
         --  bound is empty rather than an error, which is the answer
         --  a message's fields give outside a loop.
         declare
            At_Message : Natural := Call_Message;
            At_Call    : Natural := Call_At;
         begin
            if Item.Call_Slot /= 0
              and then Slots (Item.Call_Slot).Kind = Value_Call
            then
               At_Message := Slots (Item.Call_Slot).Offset;
               At_Call := Slots (Item.Call_Slot).Start;
            end if;

            if At_Message = 0 or else At_Call = 0
              or else At_Message > Count
            then
               return "";
            elsif Value.Kind = Term_Call_Name then
               return Conv.Call_Name (Messages, At_Message, At_Call);
            else
               return Conv.Call_Arguments
                 (Messages, At_Message, At_Call);
            end if;
         end;
      when Term_Indexed_Role | Term_Indexed_Content =>
         --  Counted from zero in the template and from one here, and
         --  from wherever the list it names begins, which a template
         --  moves when it lifts the system message out. A position the
         --  conversation does not reach is empty rather than an error,
         --  which is what a template comparing it against a role name
         --  expects.
         declare
            Holder : Slot renames Slots (Value.Length);
            Wanted : constant Long_Long_Integer :=
              (if Value.Index_At = 0
               then Long_Long_Integer (Value.Offset)
               else Number_Of
                      (Value_Of (Item.Operands.all (Value.Index_At))));
            At_Message : constant Natural :=
              Message_At (Holder.Start, Slot_Last (Holder), Wanted);
         begin
            if Holder.Kind /= Value_List then
               --  A list of mappings -- what selectattr leaves of the
               --  messages -- read the way any list's element is.
               return Printed
                 (Field_Of (Element_At (Held_Of (Value.Length), Wanted),
                            (if Value.Kind = Term_Indexed_Role
                             then "role" else "content")));
            elsif At_Message = 0 then
               return "";
            elsif Value.Kind = Term_Indexed_Role then
               return Conv.Role_Name
                 (Conv.Sender_At (Messages, At_Message));
            else
               return Conv.Content_At (Messages, At_Message);
            end if;
         end;
      when Term_Generation_Prompt =>
         return (if Add_Generation_Prompt then "true" else "");
      when Term_Loop_First =>
         if Innermost_Is_New then
            return (if Loops (Loop_Depth).Index = 1 then "true" else "");
         elsif In_Calls then
            return (if Call_At = 1 then "true" else "");
         end if;
         return (if Current = Loop_Start then "true" else "");
      when Term_Loop_Last =>
         if Innermost_Is_New then
            return (if Loops (Loop_Depth).Index = Loops (Loop_Depth).Total
                    then "true" else "");
         elsif In_Calls then
            return (if Call_At = Walking_Count then "true" else "");
         end if;
         return (if Current = Loop_Stop and then Loop_Stop > 0
                 then "true" else "");
      when Term_Loop_Index_Zero =>
         if Innermost_Is_New then
            return Model_Runner.Text.Image
              (Long_Long_Integer (Loops (Loop_Depth).Index) - 1);
         elsif In_Calls then
            return Model_Runner.Text.Image
              (Long_Long_Integer (Call_At) - 1);
         end if;
         return Model_Runner.Text.Image
           (Long_Long_Integer (Current) - Long_Long_Integer (Loop_Start));
      when Term_Loop_Length =>
         return Model_Runner.Text.Image (Long_Long_Integer (Loop_Total));
      when Term_Loop_Rev_Index_Zero =>
         return Model_Runner.Text.Image
           (Long_Long_Integer (Loop_Total) - Loop_Index);
      when Term_Loop_Rev_Index_One =>
         return Model_Runner.Text.Image
           (Long_Long_Integer (Loop_Total) - Loop_Index + 1);
      when Term_Loop_Index_One =>
         if Innermost_Is_New then
            return Model_Runner.Text.Image
              (Long_Long_Integer (Loops (Loop_Depth).Index));
         elsif In_Calls then
            return Model_Runner.Text.Image (Long_Long_Integer (Call_At));
         end if;
         return Model_Runner.Text.Image
           (Long_Long_Integer (Current) - Long_Long_Integer (Loop_Start)
            + 1);
      when Term_True =>
         return "true";
      when Term_False | Term_None =>
         return "";
      when Term_Variable =>
         declare
            Holder : Slot renames Slots (Value.Offset);
            Name   : Variable_Name renames Item.Names (Value.Offset);
         begin
            case Holder.Kind is
               when Value_Text | Value_Number =>
                  return Pool (Holder.Offset + 1
                               .. Holder.Offset + Holder.Length);
               when Value_Data =>
                  return Pythonic
                    (Pool (Holder.Offset + 1
                           .. Holder.Offset + Holder.Length));
               when Value_None =>
                  return "";
               when Value_Boolean =>
                  return (if Holder.Offset = 1 then "true" else "");
               when Value_Undefined =>
                  --  A name never assigned is nothing. Asked about in
                  --  a condition that is the answer -- a template
                  --  writes "if tools" precisely to find out whether
                  --  it was given any -- and asked for in output it is
                  --  a template reading something it never wrote,
                  --  which would put the empty string where it meant
                  --  text and say nothing about it.
                  if not Testing then
                     Refuse (Name.Offset, Name.Length,
                             E.Template_Unknown_Variable);
                  end if;
                  return "";
               when Value_Tools | Value_JSON =>
                  --  The tools, or one of them. Asked about in a
                  --  condition the answer is that there is something
                  --  there -- "if tools" is written to find out
                  --  whether the caller offered any -- and asked for
                  --  as text it is a template printing an object,
                  --  which has no spelling this engine may choose.
                  --  Written with tojson it never reaches here.
                  if Testing then
                     return "true";
                  end if;

                  Refuse (Name.Offset, Name.Length,
                          E.Template_Unsupported_Construct);
                  return "";

               when Value_List | Value_Message | Value_Call =>
                  --  A list, a message and a call have no text. Asking
                  --  one for its text is a template doing something
                  --  this engine does not model, not a template asking
                  --  for the empty string.
                  Refuse (Name.Offset, Name.Length,
                          E.Template_Unsupported_Construct);
                  return "";
            end case;
         end;
      when Term_Now =>
         return Now_As
           (Item.Source.all
              (Value.Offset + 1 .. Value.Offset + Value.Length),
            Value);

      when Term_Raise =>
         --  The template's author refusing this conversation, in
         --  their words. Not a construct this engine lacks: the
         --  message is the diagnostic.
         Refuse (Value.Offset, Value.Length, E.Template_Refused);
         return "";

      when Term_Group =>
         return Value_Of (Item.Operands.all (Value.Offset));

      when Term_Macro =>
         return Run_Macro (Value);

      when Term_Keyword =>
         --  Read by the call it belongs to, never on its own.
         return "";

      when Term_List | Term_Dict | Term_Loop_Previous | Term_Loop_Next
         | Term_Condition | Term_Choice | Term_Or | Term_And =>
         return Printed (Base_Of (Value));

      when Term_Unsupported =>
         --  A name this engine has never heard of is nothing when a
         --  condition asks about it -- a template writes "if
         --  message.tool_calls" to find out whether there are any --
         --  and a refusal when the output asks for it. A construct it
         --  cannot evaluate refuses either way: there is no answer to
         --  give, and a condition guessed at is a branch taken for no
         --  reason.
         if Testing and then Value.Why = E.Template_Unknown_Variable
         then
            return "";
         end if;

         Refuse (Value.Offset, Value.Length, Value.Why);
         return "";
   end case;
end Raw_Of;
