separate (Model_Runner.Templates.Compile)
procedure Compile_Set (Text : String) is
   Scan        : Natural := Text'First;
   First, Last : Natural;
   Target      : Natural := 0;
   Where       : Natural;
begin
   Read_Word (Text, Scan, First, Last);
   if Last >= First
     and then (Is_Plain_Name (Text (First .. Last))
               or else Is_Namespace_Field (Text (First .. Last)))
   then
      Target := Slot_Of (Text (First .. Last));
   end if;

   --  The block form, a name and nothing after it: what is written
   --  up to the endset is the name's value rather than the prompt's.
   if Target /= 0 and then Skip_Spaces (Text, Scan) > Text'Last then
      if Depth >= Max_Depth then
         Fail (E.Template_Nesting_Too_Deep, "set");
         return;
      end if;
      Emit ((Op => Op_Capture_Begin, others => <>), Where);
      if Where = 0 then
         return;
      end if;
      Depth := Depth + 1;
      Frames (Depth) := (Kind => Block_Set, Start => Target,
                         others => <>);
      return;
   end if;

   declare
      Equals : constant Natural := Skip_Spaces (Text, Scan);
   begin
      if Target = 0
        or else Equals > Text'Last
        or else Text (Equals) /= '='
        or else (Equals < Text'Last and then Text (Equals + 1) = '=')
      then
         Refuse (Text, Where);
         return;
      end if;

      declare
         Rest : constant String :=
           Model_Runner.Text.Trim (Text (Equals + 1 .. Text'Last));
         Head : Natural := Rest'First;
         Name : Natural := 0;
      begin
         if Rest = "none" then
            Emit ((Op => Op_Set_None, Offset => Target, others => <>),
                  Where);
            return;
         end if;

         --  list.append(x) and list.pop(n), the two ways a template
         --  changes a list in place, as the assignments they amount
         --  to: the list grown or cut, and the name set to what the
         --  call returns.
         declare
            Open : Natural := 0;
         begin
            for Position in Rest'Range loop
               exit when Rest (Position) not in
                 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.';
               Open := Position;
            end loop;
            if Open > Rest'First and then Open < Rest'Last
              and then Rest (Open + 1) = '('
              and then Rest (Rest'Last) = ')'
              and then Closes_At (Rest, Open + 1) = Rest'Last
            then
               declare
                  Called : constant String := Rest (Rest'First .. Open);
                  Inside : constant String :=
                    Model_Runner.Text.Trim
                      (Rest (Open + 2 .. Rest'Last - 1));
                  Name   : constant String := Text (First .. Last);
               begin
                  if Model_Runner.Text.Ends_With (Called, ".append")
                    and then Called'Length > 7
                    and then Inside /= ""
                  then
                     declare
                        List : constant String :=
                          Called (Called'First .. Called'Last - 7);
                     begin
                        Compile_Set
                          (List & " = " & List & " + [" & Inside & "]");
                        Emit ((Op => Op_Set_None, Offset => Target,
                               others => <>), Where);
                        return;
                     end;
                  elsif Model_Runner.Text.Ends_With (Called, ".pop")
                    and then Called'Length > 4
                    and then (Inside in "" | "-1"
                              or else (Inside'Length <= 4
                                       and then (for all C of Inside =>
                                                   C in '0' .. '9')))
                  then
                     declare
                        List : constant String :=
                          Called (Called'First .. Called'Last - 4);
                        At_Text : constant String :=
                          (if Inside = "" then "-1" else Inside);
                     begin
                        Compile_Set (Name & " = " & List
                                     & "[" & At_Text & "]");
                        if At_Text = "-1" then
                           Compile_Set (List & " = " & List & "[:-1]");
                        else
                           Compile_Set
                             (List & " = " & List & "[:" & At_Text
                              & "] + " & List & "["
                              & Model_Runner.Text.Image
                                  (Long_Long_Integer'Value (At_Text)
                                   + 1)
                              & ":]");
                        end if;
                        return;
                     end;
                  end if;
               end;
            end if;
         end;

         --  namespace(a = x, b = y): a holder with named fields, which
         --  becomes one ordinary assignment per field. The name of the
         --  holder is remembered so that ns.a reads as a name later,
         --  and is not confused with message.role, which is spelled
         --  the same way and is not a name.
         if Model_Runner.Text.Starts_With (Rest, "namespace(") then
            declare
               Shut : Natural := Rest'Last;
            begin
               while Shut >= Rest'First and then Rest (Shut) /= ')' loop
                  Shut := Shut - 1;
               end loop;

               if Shut < Rest'First then
                  Refuse (Text, Where);
                  return;
               end if;

               Namespaces (Target) := True;
               Emit ((Op => Op_Namespace_New, Offset => Target,
                      others => <>), Where);

               declare
                  Fields : constant String :=
                    Rest (Rest'First + 10 .. Shut - 1);
                  Head_Name : constant String := Text (First .. Last);
                  At_Field  : Natural := Fields'First;
               begin
                  while At_Field <= Fields'Last loop
                     declare
                        Ends : Natural := At_Field;
                        Level : Natural := 0;
                     begin
                        --  One field a comma, and a comma inside
                        --  brackets belongs to what is inside them.
                        --  A quoted comma belongs to the text, and a
                        --  field may sit on a line of its own.
                        while Ends <= Fields'Last loop
                           if Fields (Ends) in ''' | '"' then
                              declare
                                 Quote : constant Character :=
                                   Fields (Ends);
                              begin
                                 Ends := Ends + 1;
                                 while Ends <= Fields'Last
                                   and then Fields (Ends) /= Quote
                                 loop
                                    if Fields (Ends) = '\' then
                                       Ends := Ends + 1;
                                    end if;
                                    Ends := Ends + 1;
                                 end loop;
                              end;
                           elsif Fields (Ends) in '(' | '[' | '{' then
                              Level := Level + 1;
                           elsif Fields (Ends) in ')' | ']' | '}'
                             and then Level > 0
                           then
                              Level := Level - 1;
                           elsif Fields (Ends) = ',' and then Level = 0
                           then
                              exit;
                           end if;
                           Ends := Ends + 1;
                        end loop;

                        declare
                           Field_First : Natural := At_Field;
                           Field_Last  : Natural :=
                             Natural'Min (Ends - 1, Fields'Last);
                        begin
                           while Field_First <= Field_Last
                             and then Fields (Field_First) in
                               ' ' | ASCII.LF | ASCII.CR | ASCII.HT
                           loop
                              Field_First := Field_First + 1;
                           end loop;
                           while Field_Last >= Field_First
                             and then Fields (Field_Last) in
                               ' ' | ASCII.LF | ASCII.CR | ASCII.HT
                           loop
                              Field_Last := Field_Last - 1;
                           end loop;
                           if Field_Last >= Field_First then
                              Compile_Set
                                (Head_Name & "."
                                 & Fields (Field_First .. Field_Last));
                           end if;
                        end;
                        At_Field := Ends + 1;
                     end;
                  end loop;
               end;
               return;
            end;
         end if;

         --  The keywords are values, not names: taking true for a name
         --  copies an undefined slot, and the template that set it then
         --  looks like one reading a variable it never assigned.
         Read_Word (Rest, Head, First, Last);
         if Last >= First
           and then Is_Plain_Name (Rest (First .. Last))
           and then Rest (First .. Last) not in "true" | "false" | "none"
         then
            Name := Slot_Of (Rest (First .. Last));
         end if;

         --  A whole list under a second name. Assigning the value
         --  rather than its text is what lets a template rename the
         --  message list and then loop over the new name.
         if Name /= 0 and then Skip_Spaces (Rest, Head) > Rest'Last then
            Emit ((Op => Op_Set_Copy, Offset => Target, Target => Name,
                   others => <>), Where);
            return;
         end if;

         --  One message of a list, named by a position the template
         --  works out: messages[index] and its like. What a template
         --  does when it walks the conversation by number rather than
         --  by loop, which is the only way to walk it backwards.
         if Name /= 0 and then Head <= Rest'Last
           and then Rest (Head) = '['
           and then Rest (Rest'Last) = ']'
         then
            declare
               Inside : constant String :=
                 Model_Runner.Text.Trim
                   (Rest (Head + 1 .. Rest'Last - 1));
               Where_At : Natural := Inside'First;
               Index    : Operand;
               Taken    : Boolean;
               Kept     : Natural;
            begin
               --  A slice is written the same way as far as the
               --  opening bracket and means something else; it is
               --  told apart by the colon, and is handled below.
               if Inside'Length > 0
                 and then Inside (Inside'First) not in ''' | '"'
                 and then (for all Letter of Inside => Letter /= ':')
               then
                  Read_Operand (Inside, Where_At, Index, Taken);
                  if Taken
                    and then Skip_Spaces (Inside, Where_At)
                             > Inside'Last
                  then
                     Keep (Index, Kept);
                     if Kept = 0 then
                        return;
                     end if;
                     Emit ((Op => Op_Set_Message, Offset => Target,
                            Target => Name, Value_At => Kept,
                            others => <>), Where);
                     return;
                  end if;
               end if;
            end;
         end if;

         --  A list with a leading slice removed: messages[1:] and its
         --  like. Only a front slice is supported, because that is what
         --  a template does when it lifts the system message out of the
         --  conversation before looping over the rest.
         if Name /= 0 and then Head <= Rest'Last
           and then Rest (Head) = '['
         then
            declare
               Digits_At : Natural := Head + 1;
               Dropped   : Natural := 0;
            begin
               while Digits_At <= Rest'Last
                 and then Rest (Digits_At) in '0' .. '9'
               loop
                  Dropped := Dropped * 10
                    + Character'Pos (Rest (Digits_At))
                    - Character'Pos ('0');
                  Digits_At := Digits_At + 1;
               end loop;

               --  Only a slice, and only a whole one. Anything else
               --  starting with a bracket -- messages[0]['content'],
               --  most of all -- is an expression, and falls through
               --  to be read as one.
               if Digits_At > Head + 1
                 and then Digits_At + 1 <= Rest'Last
                 and then Rest (Digits_At .. Digits_At + 1) = ":]"
                 and then Skip_Spaces (Rest, Digits_At + 2) > Rest'Last
               then
                  Emit ((Op => Op_Set_Slice, Offset => Target,
                         Target => Name, Length => Dropped,
                         others => <>), Where);
                  return;
               end if;
            end;
         end if;

         --  A choice written on one line: A if C else B. Templates
         --  write it where a turn may not carry the field they are
         --  after -- message.content if message.content is defined
         --  else '' -- and what it compiles to is what the block form
         --  compiles to, because it is the block form said in one
         --  line: the condition, a jump over the first assignment,
         --  and a jump over the second.
         declare
            At_If   : constant Natural := Word_At (Rest, "if");
            At_Else : constant Natural :=
              (if At_If = 0 then 0 else Word_At (Rest, "else", At_If + 2));
         begin
            if At_If > Rest'First and then At_Else /= 0
              and then Word_At (Rest, "if", At_Else + 4) = 0
            then
               declare
                  Whether : constant String :=
                    Model_Runner.Text.Trim
                      (Rest (At_If + 2 .. At_Else - 1));
                  Chosen  : constant String :=
                    Model_Runner.Text.Trim
                      (Rest (Rest'First .. At_If - 1));
                  Otherwise : constant String :=
                    Model_Runner.Text.Trim
                      (Rest (At_Else + 4 .. Rest'Last));

                  Test  : Condition;
                  Valid : Boolean;
                  Held  : Natural;
                  Over_First, Over_Second : Natural := 0;

                  --  Assign one side, answering where the
                  --  instruction landed or zero when it could not
                  --  be read or could not be kept.
                  procedure Assign (Source : String; At_Step : out Natural)
                  is
                     Value : Operand;
                     Read  : Boolean;
                     Scan  : Natural := Source'First;
                     Kept  : Natural;
                  begin
                     At_Step := 0;
                     Read_Operand (Source, Scan, Value, Read);
                     if not Read
                       or else Skip_Spaces (Source, Scan) <= Source'Last
                     then
                        return;
                     end if;

                     Keep (Value, Kept);
                     if Kept = 0 then
                        return;
                     end if;
                     Emit ((Op => Op_Set_Value, Offset => Target,
                            Value_At => Kept, others => <>), At_Step);
                  end Assign;
               begin
                  Read_Condition (Whether, Test, Valid);
                  if not Valid then
                     Refuse (Text, Where);
                     return;
                  end if;

                  Keep (Test, Held);
                  if Held = 0 then
                     return;
                  end if;

                  Emit ((Op => Op_Jump_If_False, Test_At => Held,
                         others => <>), Over_First);
                  if Over_First = 0 then
                     return;
                  end if;

                  Assign (Chosen, Where);
                  if Where = 0 then
                     Refuse (Text, Where);
                     return;
                  end if;

                  Emit ((Op => Op_Jump, others => <>), Over_Second);
                  if Over_Second = 0 then
                     return;
                  end if;
                  Item.Program.all (Over_First).Target := Over_Second + 1;

                  Assign (Otherwise, Where);
                  if Where = 0 then
                     Refuse (Text, Where);
                     return;
                  end if;
                  Item.Program.all (Over_Second).Target :=
                    Item.Program_Used + 1;
                  return;
               end;
            end if;
         end;

         declare
            Value : Operand;
            Valid : Boolean;
            From  : Natural := Rest'First;
            Kept  : Natural;
         begin
            Read_Operand (Rest, From, Value, Valid);
            if not Valid
              or else Skip_Spaces (Rest, From) <= Rest'Last
            then
               --  Or a comparison assigned, "set ok = a == b".
               declare
                  Group : Term;
                  Read  : Boolean;
               begin
                  Read_Value_Group (Rest, Group, Read);
                  if not Read then
                     Refuse (Text, Where);
                     return;
                  end if;
                  Value := (Terms => [1 => Group, others => <>],
                            Count => 1);
               end;
            end if;

            Keep (Value, Kept);
            if Kept = 0 then
               return;
            end if;
            Emit ((Op => Op_Set_Value, Offset => Target,
                   Value_At => Kept, others => <>), Where);
         end;
      end;
   end;
end Compile_Set;
