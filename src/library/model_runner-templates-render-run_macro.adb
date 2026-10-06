separate (Model_Runner.Templates.Render)
function Run_Macro (Value : Term) return String is
   --  caller() is the body the call block in force wrapped up.
   Which  : constant Natural :=
     (if Value.Offset /= 0 then Value.Offset
      else Callers (Call_Depth));
   Mark   : constant Natural := Last;
   Resume : constant Natural := Position;
   Given  : array (1 .. Max_Parameters) of Held;
begin
   if Which = 0 then
      Refuse (0, 0, E.Template_Unsupported_Construct);
      return "";
   end if;
   declare
      M : Macro renames Item.Macros (Which);
   begin
      if M.Entry_At = 0 then
         --  Called before the line that defines it has run.
         Refuse (M.Name.Offset, M.Name.Length,
                 E.Template_Unknown_Variable);
         return "";
      elsif Call_Depth >= Max_Depth or else Loop_Depth >= Max_Loops then
         Refuse (M.Name.Offset, M.Name.Length, E.Template_Nesting_Too_Deep);
         return "";
      end if;

      --  What the arguments are worth, kinds and all: a list read out
      --  of a schema arrives as a list, and a parameter the call leaves
      --  out with no default is nothing, which "is defined" answers.
      --  Positional arguments in order, a keyword one to the
      --  parameter of its name.
      declare
         Set    : array (1 .. Max_Parameters) of Boolean :=
           [others => False];
         Next_P : Positive := 1;
         Arg    : Natural := 0;
      begin
         while Arg < Value.Length loop
            declare
               Given_Op : Operand renames
                 Item.Operands.all (Value.Index_At + Arg);
            begin
               if Given_Op.Count = 1
                 and then Given_Op.Terms (1).Kind = Term_Keyword
               then
                  declare
                     Key : constant String :=
                       Item.Source.all
                         (Given_Op.Terms (1).Offset + 1
                          .. Given_Op.Terms (1).Offset
                             + Given_Op.Terms (1).Length);
                  begin
                     for P in 1 .. M.Count loop
                        declare
                           Named : Variable_Name renames
                             Item.Names (M.Slots (P));
                        begin
                           if Item.Source.all
                                (Named.Offset + 1
                                 .. Named.Offset + Named.Length) = Key
                             and then Arg + 1 < Value.Length
                           then
                              Given (P) := Held_Of
                                (Item.Operands.all
                                   (Value.Index_At + Arg + 1));
                              Set (P) := True;
                           end if;
                        end;
                     end loop;
                  end;
                  Arg := Arg + 2;
               else
                  if Next_P <= M.Count then
                     Given (Next_P) := Held_Of (Given_Op);
                     Set (Next_P) := True;
                  end if;
                  Next_P := Next_P + 1;
                  Arg := Arg + 1;
               end if;
            end;
         end loop;
         for P in 1 .. M.Count loop
            if Set (P) then
               null;
            elsif M.Defaults (P) /= 0 then
               Given (P) := Held_Of (Item.Operands.all (M.Defaults (P)));
            else
               Given (P) := Nothing;
            end if;
         end loop;
      end;

      --  The body's names are its own: what it assigns, its parameters
      --  included, is put back when it returns, as a loop's are.
      Push_Loop ((Kind => Macro_Call, others => <>));
      for P in 1 .. M.Count loop
         Slots (M.Slots (P)) := (Kind => Value_Undefined, others => <>);
         Store (M.Slots (P), Given (P));
      end loop;

      Call_Depth := Call_Depth + 1;
      Callers (Call_Depth) := Pending_Caller;
      Pending_Caller := 0;
      Position := M.Entry_At;
      Returned := False;
      while not Returned and then Position <= Item.Program_Used
        and then not Refused and then not Overflow and then not Exhausted
      loop
         Execute;
      end loop;
      Call_Depth := Call_Depth - 1;
      Returned := False;

      Pop_Loop;
      Position := Resume;

      declare
         Written : constant String :=
           Target (Target'First + Mark .. Target'First + Last - 1);
      begin
         Last := Mark;
         return Written;
      end;
   end;
end Run_Macro;
