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

         procedure Bind_Positional (Value : Held) is
         begin
            if Next_P <= M.Count then
               Given (Next_P) := Value;
               Set (Next_P) := True;
            end if;
            Next_P := Next_P + 1;
         end Bind_Positional;

         procedure Bind_Keyword (Key : String; Value : Held) is
         begin
            for P in 1 .. M.Count loop
               declare
                  Named : Variable_Name renames Item.Names (M.Slots (P));
               begin
                  if Item.Source.all
                       (Named.Offset + 1 .. Named.Offset + Named.Length) = Key
                  then
                     Given (P) := Value;
                     Set (P) := True;
                  end if;
               end;
            end loop;
         end Bind_Keyword;

         procedure Expand_Positionals (Value : Held) is
            Src    : constant String := Structure_Of (Value);
            Cursor : Natural := Src'First + 1;
            Piece  : Span;
            Found  : Boolean;
         begin
            if not Is_JSON_List (Src) then
               Refuse (M.Name.Offset, M.Name.Length,
                       E.Template_Unsupported_Construct);
               return;
            end if;
            loop
               Next_Element (Src, Cursor, Piece, Found);
               exit when not Found;
               Bind_Positional (Read_Out (Src (Piece.First .. Piece.Last)));
            end loop;
         end Expand_Positionals;

         procedure Expand_Keywords (Value : Held) is
            Src    : constant String := Structure_Of (Value);
            Cursor : Natural := Src'First + 1;
            Key, Piece : Span;
            Found  : Boolean;
         begin
            if not Is_JSON_Mapping (Src) then
               Refuse (M.Name.Offset, M.Name.Length,
                       E.Template_Unsupported_Construct);
               return;
            end if;
            loop
               Next_Member (Src, Cursor, Key, Piece, Found);
               exit when not Found;
               Bind_Keyword
                 (Decoded (Src (Key.First .. Key.Last)),
                  Read_Out (Src (Piece.First .. Piece.Last)));
            end loop;
         end Expand_Keywords;
      begin
         while Arg < Value.Length loop
            declare
               Given_Op : Operand renames
                 Item.Operands.all (Value.Index_At + Arg);
            begin
               if Given_Op.Count = 1
                 and then Given_Op.Terms (1).Kind in
                   Term_Keyword | Term_Positional_Unpack | Term_Keyword_Unpack
               then
                  if Arg + 1 < Value.Length then
                     declare
                        Actual : constant Held :=
                          Held_Of
                            (Item.Operands.all (Value.Index_At + Arg + 1));
                     begin
                        case Given_Op.Terms (1).Kind is
                           when Term_Keyword =>
                              Bind_Keyword
                                (Item.Source.all
                                   (Given_Op.Terms (1).Offset + 1
                                    .. Given_Op.Terms (1).Offset
                                       + Given_Op.Terms (1).Length),
                                 Actual);
                           when Term_Positional_Unpack =>
                              Expand_Positionals (Actual);
                           when Term_Keyword_Unpack =>
                              Expand_Keywords (Actual);
                           when others =>
                              null;
                        end case;
                     end;
                  end if;
                  Arg := Arg + 2;
               else
                  Bind_Positional (Held_Of (Given_Op));
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
