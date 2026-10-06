separate (Model_Runner.Templates.Compile)
procedure Mark_Numeric_Names is
   type Number_State is (Unset, Only_Numbers, Mixed);
   States  : array (1 .. Max_Variables) of Number_State :=
     [others => Unset];
   Changed : Boolean := True;

   procedure Note (Slot : Natural; Numeric : Boolean) is
   begin
      if Slot = 0 then
         return;
      end if;
      if not Numeric then
         States (Slot) := Mixed;
      elsif States (Slot) = Unset then
         States (Slot) := Only_Numbers;
      end if;
   end Note;

   --  Whether a term reads a number-only name, plainly.
   function Reads_Number (Value : Term) return Boolean
   is (Value.Kind = Term_Variable
       and then Value.Offset /= 0
       and then Value.Path_Len = 0 and then Value.Tail_Len = 0
       and then not Value.Indexes
       and then Value.Chained = 0 and then Value.Filtered = 0
       and then States (Value.Offset) = Only_Numbers);

   --  Mark the terms of one operand, answering whether any changed.
   function Mark (Value : in out Operand) return Boolean is
      Any : Boolean := False;
   begin
      for Index in 1 .. Value.Count loop
         declare
            T : Term renames Value.Terms (Index);
         begin
            if not T.Numeric then
               if Reads_Number (T) then
                  T.Numeric := True;
                  Any := True;
               elsif T.Kind = Term_Group and then T.Offset /= 0
                 and then Sums (Item.Operands.all (T.Offset))
               then
                  T.Numeric := True;
                  Any := True;
               end if;
            end if;
         end;
      end loop;
      return Any;
   end Mark;
begin
   --  Every assignment the program makes, by the instruction that
   --  makes it. Copies are settled after the rest, and repeatedly,
   --  because a copy of a copy is a number only once its source is.
   for Step of Item.Program.all (1 .. Item.Program_Used) loop
      case Step.Op is
         when Op_Set_Value =>
            Note (Step.Offset, Sums (Item.Operands.all (Step.Value_At)));
         when Op_Range_Begin =>
            Note (Step.Offset, True);
         when Op_Set_Copy =>
            null;
         when Op_Set_None | Op_Set_Slice | Op_Set_Message
            | Op_Capture_End | Op_Call_Begin =>
            Note (Step.Offset, False);
         when Op_Each_Begin =>
            Note (Step.Offset, False);
            Note (Step.Length, False);
         when Op_For_Begin =>
            if Step.Binds then
               Note (Item.Message_Slot, False);
            end if;
         when others =>
            null;
      end case;
   end loop;
   for M in 1 .. Item.Macro_Used loop
      for P in 1 .. Item.Macros (M).Count loop
         Note (Item.Macros (M).Slots (P), False);
      end loop;
   end loop;
   while Changed loop
      Changed := False;
      for Step of Item.Program.all (1 .. Item.Program_Used) loop
         if Step.Op = Op_Set_Copy and then Step.Offset /= 0
           and then Step.Target /= 0
         then
            if States (Step.Target) = Mixed
              and then States (Step.Offset) /= Mixed
            then
               States (Step.Offset) := Mixed;
               Changed := True;
            elsif States (Step.Target) = Only_Numbers
              and then States (Step.Offset) = Unset
            then
               States (Step.Offset) := Only_Numbers;
               Changed := True;
            end if;
         end if;
      end loop;
   end loop;

   --  Then every term that reads one, until nothing more changes:
   --  a group is a sum once the terms inside it are numbers.
   Changed := True;
   while Changed loop
      Changed := False;
      for Index in 1 .. Item.Operand_Used loop
         if Mark (Item.Operands.all (Index)) then
            Changed := True;
         end if;
      end loop;
      for Index in 1 .. Item.Condition_Used loop
         for C in 1 .. Item.Conditions.all (Index).Clause_Used loop
            if Mark (Item.Conditions.all (Index).Clauses (C).Left) then
               Changed := True;
            end if;
            if Mark (Item.Conditions.all (Index).Clauses (C).Right) then
               Changed := True;
            end if;
         end loop;
      end loop;
   end loop;
end Mark_Numeric_Names;
