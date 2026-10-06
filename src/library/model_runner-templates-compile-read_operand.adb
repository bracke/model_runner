separate (Model_Runner.Templates.Compile)
procedure Read_Operand
  (Text   : String;
   From   : in out Natural;
   Result : out Operand;
   Ok     : out Boolean)
is
   Value  : Term;
   Taken  : Boolean;
   Joined : Join_Kind := Join_Plus;

   --  Where the join's spelling was kept, for the joins that may
   --  refuse.
   Join_At, Join_Len : Natural := 0;

   --  Add one term to what has been read, under the join in force.
   --  Answers False where there is no room, which refuses the operand
   --  rather than dropping a term out of the middle of a sum.
   function Push (Held : Term; Under : Join_Kind) return Boolean is
   begin
      if Result.Count >= Max_Terms then
         return False;
      end if;
      Result.Count := Result.Count + 1;
      Result.Terms (Result.Count) := Held;
      Result.Terms (Result.Count).Join := Under;
      Result.Terms (Result.Count).Join_At := Join_At;
      Result.Terms (Result.Count).Join_Len := Join_Len;
      return True;
   end Push;
begin
   Result := (others => <>);
   Ok := False;

   loop
      declare
         Restart : constant Natural := From;
      begin
         Read_Term (Text, From, Value, Taken);

         if Taken then
            if not Push (Value, Joined) then
               return;
            end if;
         else
            --  A bracketed group holding a sum. One holding a single
            --  value is a term and was read as one above, methods and
            --  all; this is the other kind, kept as an operand of its
            --  own and read as one term, so that what is written
            --  outside the brackets binds to the whole of what is
            --  inside them. It used to be spliced into the sum around
            --  it, which is the same thing while the only joins are
            --  plus and minus and a wrong thing once a product is
            --  written outside.
            From := Restart;

            declare
               Opens : constant Natural := Skip_Spaces (Text, From);
               Shut  : Natural := 0;
            begin
               exit when Opens > Text'Last or else Text (Opens) /= '(';

               Shut := Closes_At (Text, Opens);
               if Shut = 0 or else Group_Depth >= Max_Depth then
                  return;
               end if;

               declare
                  Held  : constant String :=
                    Text (Opens + 1 .. Shut - 1);
                  Inner : Operand;
                  Scan  : Natural := Held'First;
                  Read  : Boolean;
               begin
                  Group_Depth := Group_Depth + 1;
                  Read_Operand (Held, Scan, Inner, Read);
                  Group_Depth := Group_Depth - 1;

                  --  All of it, or none: a group with anything left
                  --  unread in it is not the sum it looks like -- it
                  --  may be a choice or a comparison written as a
                  --  value, which are read as such.
                  if not Read
                    or else Skip_Spaces (Held, Scan) <= Held'Last
                  then
                     declare
                        Group : Term;
                        Valid : Boolean;
                     begin
                        Group_Depth := Group_Depth + 1;
                        Read_Value_Group (Held, Group, Valid);
                        Group_Depth := Group_Depth - 1;
                        if not Valid then
                           return;
                        end if;
                        From := Shut + 1;
                        Read_Tail (Text, From, Group);
                        if not Push (Group, Joined) then
                           return;
                        end if;
                        goto Joined_On;
                     end;
                  end if;

                  declare
                     Kept  : Natural;
                     Group : Term;
                  begin
                     Keep (Inner, Kept);
                     if Kept = 0 then
                        return;
                     end if;
                     Group.Kind := Term_Group;
                     Group.Offset := Kept;
                     Group.Numeric := Sums (Inner);
                     From := Shut + 1;
                     Read_Tail (Text, From, Group);
                     if not Push (Group, Joined) then
                        return;
                     end if;
                  end;
               end;
            end;
         end if;
      end;

      <<Joined_On>>
      declare
         Next : constant Natural := Skip_Spaces (Text, From);
      begin
         exit when Next > Text'Last
           or else Text (Next) not in '+' | '-' | '*' | '/' | '%' | '~';

         --  Which way the next term joins this one, carried on that
         --  term rather than here: an operand is a list and the join
         --  belongs between two of its entries.
         From := Next + 1;
         Join_At := 0;
         Join_Len := 0;
         case Text (Next) is
            when '-' => Joined := Join_Minus;
            when '*' =>
               if Next < Text'Last and then Text (Next + 1) = '*' then
                  Joined := Join_Power;
                  From := Next + 2;
               else
                  Joined := Join_Times;
               end if;
            when '~' => Joined := Join_Concat;
            when '%' | '/' =>
               if Text (Next) = '%' then
                  Joined := Join_Modulo;
               elsif Next < Text'Last and then Text (Next + 1) = '/' then
                  Joined := Join_Floor;
                  From := Next + 2;
               else
                  Joined := Join_Divide;
               end if;
               declare
                  Stored : Boolean;
               begin
                  Store_Literal
                    (Text (Next .. From - 1), Join_At, Join_Len, Stored);
                  if not Stored then
                     return;
                  end if;
               end;
            when others =>
               Joined := Join_Plus;
               declare
                  Stored : Boolean;
               begin
                  Store_Literal
                    (Text (Next .. Next), Join_At, Join_Len, Stored);
                  if not Stored then
                     return;
                  end if;
               end;
         end case;
      end;
   end loop;

   Ok := Result.Count > 0;
end Read_Operand;
