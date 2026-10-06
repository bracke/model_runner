separate (Model_Runner.Templates.Render)
procedure Execute is
begin
   Iterations := Iterations + 1;
   if Iterations > Item.Step_Limit then
      Exhausted := True;
      Position := Item.Program_Used + 1;
      return;
   end if;

   declare
      Step : Instruction renames Item.Program.all (Position);
   begin
      case Step.Op is
         when Op_Text =>
            Put (Item.Source.all
                   (Step.Offset + 1 .. Step.Offset + Step.Length));
            Position := Position + 1;

         when Op_Output =>
            Emit_Operand (Item.Operands.all (Step.Value_At));
            Position := Position + 1;

         when Op_For_Begin =>
            declare
               Holder : Slot renames Slots (Step.Offset);
            begin
               if Holder.Kind /= Value_List then
                  Refuse (Item.Names (Step.Offset).Offset,
                          Item.Names (Step.Offset).Length,
                          E.Template_Unsupported_Construct);
                  Position := Position + 1;
               elsif Holder.Start > Slot_Last (Holder) then
                  Position := Step.Target;
               else
                  Loop_Start := Holder.Start;
                  Loop_Stop := Slot_Last (Holder);
                  Current := Holder.Start;
                  if Step.Binds then
                     Bind_Message (Current);
                  end if;
                  Push_Loop ((Kind => Legacy_List, others => <>));
                  Position := Position + 1;
               end if;
            end;

         when Op_For_Next =>
            if Current < Loop_Stop and then not Breaking then
               Current := Current + 1;
               if Step.Binds then
                  Bind_Message (Current);
               end if;
               Position := Step.Target + 1;
            else
               Current := 0;
               if Step.Binds then
                  Bind_Message (0);
               end if;
               Pop_Loop;
               Breaking := False;
               Position := Position + 1;
            end if;

         when Op_Jump_If_False =>
            if Truth_Of (Item.Conditions.all (Step.Test_At)) then
               Position := Position + 1;
            else
               Position := Step.Target;
            end if;

         when Op_Jump =>
            Position := Step.Target;

         when Op_Break =>
            Breaking := True;
            Position := Step.Target;

         when Op_Continue =>
            Position := Step.Target;

         when Op_Set_Caller =>
            Pending_Caller := Step.Offset;
            Position := Position + 1;

         when Op_Scope_Begin =>
            if Scope_Depth < Max_Depth then
               Scope_Depth := Scope_Depth + 1;
               Scopes (Scope_Depth) := Slots;
               Scope_Floor (Scope_Depth) := Pool_Used;
            end if;
            Position := Position + 1;

         when Op_Scope_End =>
            if Scope_Depth > 0 then
               Restore_Names (Scopes (Scope_Depth),
                              Scope_Floor (Scope_Depth));
               Scope_Depth := Scope_Depth - 1;
            end if;
            Position := Position + 1;

         when Op_Discard =>
            declare
               Ignored : constant String :=
                 Value_Of (Item.Operands.all (Step.Value_At));
               pragma Unreferenced (Ignored);
            begin
               Position := Position + 1;
            end;

         when Op_Grow =>
            Grow (Step.Offset, Item.Operands.all (Step.Value_At),
                  Step.Length);
            Position := Position + 1;

         when Op_Set_Text =>
            Assign_Text
              (Step.Offset,
               Value_Of (Item.Operands.all (Step.Value_At)));
            Position := Position + 1;

         when Op_Set_Message =>
            --  Counted from zero in the template and from one here,
            --  and from wherever the list it names begins. A position
            --  the conversation does not reach binds nothing, which is
            --  what a template comparing its role against a name
            --  expects rather than an error.
            declare
               From_List : Slot renames Slots (Step.Target);
               Wanted : constant Long_Long_Integer :=
                 Number_Of (Value_Of (Item.Operands.all (Step.Value_At)));
               At_Message : constant Natural :=
                 Message_At (From_List.Start, Slot_Last (From_List),
                             Wanted);
            begin
               if From_List.Kind /= Value_List then
                  --  Not a list of messages: one element of whatever
                  --  the name holds, a list read out of a schema or
                  --  the pieces of a cut.
                  Store (Step.Offset,
                         Element_At (Held_Of (Step.Target), Wanted));
               elsif At_Message /= 0 then
                  Slots (Step.Offset) :=
                    (Kind => Value_Message, Offset => 0, Length => 0,
                     Start => At_Message);
               else
                  Slots (Step.Offset) := (Kind => Value_None,
                                          others => <>);
               end if;
            end;
            Position := Position + 1;

         when Op_Call_Begin =>
            --  A turn that asked for nothing skips the loop rather
            --  than running it none times, which is what the tools
            --  loop does with a caller who offered none.
            declare
               Asked : constant Natural := Asked_Count;
            begin
               if Asked = 0 then
                  Position := Step.Target;
               else
                  Call_Message := Bound_Message;
                  Call_At := 1;
                  In_Calls := True;
                  Slots (Step.Offset) :=
                    (Kind => Value_Call, Offset => Call_Message,
                     Length => 0, Start => 1);
                  Push_Loop ((Kind => Legacy_Calls, others => <>));
                  Position := Position + 1;
               end if;
            end;

         when Op_Call_Next =>
            --  Which name the loop writes to is kept in the
            --  instruction that began it, which is where this jumps
            --  back to anyway.
            declare
               Named : constant Natural :=
                 Item.Program.all (Step.Target).Offset;
               Asked : constant Natural := Walking_Count;
            begin
               if Call_At < Asked and then not Breaking then
                  Call_At := Call_At + 1;
                  Slots (Named) :=
                    (Kind => Value_Call, Offset => Call_Message,
                     Length => 0, Start => Call_At);
                  Position := Step.Target + 1;
               else
                  Call_At := 0;
                  Call_Message := 0;
                  In_Calls := False;
                  Slots (Named) := (Kind => Value_Undefined,
                                    others => <>);
                  Pop_Loop;
                  Breaking := False;
                  Position := Position + 1;
               end if;
            end;

         when Op_Range_Begin =>
            --  The three numbers are read once, where the loop begins.
            --  A template that counted from something it changes inside
            --  the loop would be a template whose end nobody can see,
            --  and this counts to where it was told to at the start.
            declare
               Bounds : Natural renames Step.Value_At;
            begin
               Range_Slot := Step.Offset;
               Range_At :=
                 Number_Of (Value_Of (Item.Operands.all (Bounds)));
               Range_Start := Range_At;
               Range_Stop :=
                 Number_Of (Value_Of (Item.Operands.all (Bounds + 1)));
               Range_Step :=
                 Number_Of (Value_Of (Item.Operands.all (Bounds + 2)));

               if Range_Step = 0 or else not Counting_On then
                  Position := Step.Target;
               else
                  Assign_Text
                    (Range_Slot, Model_Runner.Text.Image (Range_At),
                     Value_Number);
                  Push_Loop ((Kind => Legacy_Range, others => <>));
                  Position := Position + 1;
               end if;
            end;

         when Op_Range_Next =>
            Range_At := Range_At + Range_Step;
            if Counting_On and then not Breaking then
               Assign_Text
                 (Range_Slot, Model_Runner.Text.Image (Range_At),
                  Value_Number);
               Position := Step.Target + 1;
            else
               Pop_Loop;
               Breaking := False;
               Position := Position + 1;
            end if;

         when Op_Namespace_New =>
            if Loop_Depth > 0 then
               Loops (Loop_Depth).Fresh (Step.Offset) := True;
               Loops (Loop_Depth).Any_Fresh := True;
            end if;
            Position := Position + 1;

         when Op_Set_None =>
            Slots (Step.Offset) := (Kind => Value_None, others => <>);
            Position := Position + 1;

         when Op_Set_Copy =>
            --  Text is copied, and everything else is the same value
            --  named twice. A copied slot would point at the room the
            --  other name holds, and the two names then share a fate
            --  neither asked for: a template that writes
            --  "set ns.last = index" inside a loop keeps the number
            --  the loop was at, and the loop takes that room back the
            --  next time round -- so the kept number quietly becomes
            --  the current one, and a template written to find the
            --  last question in a conversation finds the first.
            --
            --  A list, a message, a tool and a call are positions
            --  rather than text and carry no room to be taken back.
            if Slots (Step.Target).Kind in Value_Text | Value_Number
            then
               Assign_Text
                 (Step.Offset,
                  Pool (Slots (Step.Target).Offset + 1
                        .. Slots (Step.Target).Offset
                           + Slots (Step.Target).Length),
                  Slots (Step.Target).Kind);
            else
               Slots (Step.Offset) := Slots (Step.Target);
            end if;
            Position := Position + 1;

         when Op_Set_Slice =>
            if Slots (Step.Target).Kind /= Value_List then
               Refuse (Item.Names (Step.Target).Offset,
                       Item.Names (Step.Target).Length,
                       E.Template_Unsupported_Construct);
            else
               Slots (Step.Offset) :=
                 (Kind  => Value_List,
                  Start => Slots (Step.Target).Start + Step.Length,
                  Length => Slots (Step.Target).Length,
                  others => <>);
            end if;
            Position := Position + 1;

         when Op_Capture_Begin =>
            --  Nesting is bounded where the blocks are compiled, so
            --  the stack cannot fill.
            Capture_Depth := Capture_Depth + 1;
            Captures (Capture_Depth) := Last;
            Position := Position + 1;

         when Op_Capture_End =>
            --  What was written since the block opened becomes the
            --  name's value and leaves the output.
            declare
               Mark : constant Natural := Captures (Capture_Depth);
            begin
               Capture_Depth := Capture_Depth - 1;
               Assign_Text
                 (Step.Offset,
                  Target (Target'First + Mark .. Target'First + Last - 1));
               Last := Mark;
            end;
            Position := Position + 1;

         when Op_Return =>
            --  The end of a macro's body. Inside a call it hands
            --  back to Run_Macro; reached otherwise -- which the jump
            --  over the body prevents -- it ends the program.
            if Call_Depth > 0 then
               Returned := True;
            else
               Position := Item.Program_Used + 1;
            end if;

         when Op_Set_Value =>
            Store (Step.Offset,
                   Held_Of (Item.Operands.all (Step.Value_At)));
            Position := Position + 1;

         when Op_Each_Begin =>
            Each_Begin (Step);

         when Op_Each_Next =>
            Each_Next (Step);

         when Op_Unsupported =>
            Refuse (Step.Offset, Step.Length,
                    E.Template_Unsupported_Construct);
            Position := Position + 1;
      end case;
   end;
end Execute;
