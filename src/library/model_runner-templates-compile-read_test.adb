separate (Model_Runner.Templates.Compile)
procedure Read_Test
  (Text    : String;
   From    : in out Natural;
   Current : in out Clause;
   Ok      : out Boolean)
is
   Probe : constant Natural := Skip_Spaces (Text, From);
   Taken : Boolean;

   --  Set where the negation is written between the two sides.
   Denied_In : Boolean := False;
begin
   Ok := True;

   if Probe + 1 <= Text'Last and then Text (Probe .. Probe + 1) = "==" then
      Current.Operator := Compare_Equal;
      From := Probe + 2;
   elsif Probe + 1 <= Text'Last
     and then Text (Probe .. Probe + 1) = "!="
   then
      Current.Operator := Compare_Not_Equal;
      From := Probe + 2;
   elsif Probe + 1 <= Text'Last
     and then Text (Probe .. Probe + 1) = ">="
   then
      Current.Operator := Compare_Greater_Or_Equal;
      From := Probe + 2;
   elsif Probe + 1 <= Text'Last
     and then Text (Probe .. Probe + 1) = "<="
   then
      Current.Operator := Compare_Less_Or_Equal;
      From := Probe + 2;
   elsif Probe <= Text'Last and then Text (Probe) = '>' then
      Current.Operator := Compare_Greater;
      From := Probe + 1;
   elsif Probe <= Text'Last and then Text (Probe) = '<' then
      Current.Operator := Compare_Less;
      From := Probe + 1;
   else
      declare
         Restore     : constant Natural := From;
         Scan        : Natural := From;
         First, Last : Natural;
      begin
         Read_Word (Text, Scan, First, Last);
         if Last < First then
            return;
         end if;

         if Text (First .. Last) = "is" then
            declare
               Denied : Boolean := False;
            begin
               From := Scan;
               Read_Word (Text, Scan, First, Last);
               if Last >= First and then Text (First .. Last) = "not" then
                  Denied := True;
                  From := Scan;
                  Read_Word (Text, Scan, First, Last);
               end if;

               if Last < First then
                  return;
               end if;
               From := Scan;

               if Text (First .. Last) = "defined" then
                  Current.Operator :=
                    (if Denied then Compare_Not_Defined
                     else Compare_Defined);
               elsif Text (First .. Last) = "none" then
                  Current.Operator :=
                    (if Denied then Compare_Is_Not_None
                     else Compare_Is_None);
               elsif Text (First .. Last) = "true" then
                  Current.Operator :=
                    (if Denied then Compare_Is_Not_True
                     else Compare_Is_True);
               elsif Text (First .. Last) = "false" then
                  Current.Operator :=
                    (if Denied then Compare_Is_Not_False
                     else Compare_Is_False);
               elsif Text (First .. Last) = "string" then
                  Current.Operator :=
                    (if Denied then Compare_Is_Not_String
                     else Compare_Is_String);
               elsif Text (First .. Last) = "mapping" then
                  Current.Operator :=
                    (if Denied then Compare_Is_Not_Mapping
                     else Compare_Is_Mapping);
               elsif Text (First .. Last) = "number" then
                  Current.Operator :=
                    (if Denied then Compare_Is_Not_Number
                     else Compare_Is_Number);
               elsif Text (First .. Last) = "sequence" then
                  Current.Operator :=
                    (if Denied then Compare_Is_Not_Sequence
                     else Compare_Is_Sequence);
               elsif Text (First .. Last) = "undefined" then
                  Current.Operator :=
                    (if Denied then Compare_Is_Not_Undefined
                     else Compare_Is_Undefined);
               elsif Text (First .. Last) = "iterable" then
                  Current.Operator :=
                    (if Denied then Compare_Is_Not_Iterable
                     else Compare_Is_Iterable);
               elsif Text (First .. Last) = "boolean" then
                  Current.Operator :=
                    (if Denied then Compare_Is_Not_Boolean
                     else Compare_Is_Boolean);
               else
                  --  A test this engine has no answer for. The clause
                  --  becomes one that refuses when it is evaluated,
                  --  which is not the same as refusing the template.
                  Current.Left :=
                    (Terms => [1 => Refused (Text (First .. Last)),
                               others => <>],
                     Count => 1);
                  Current.Operator := Compare_None;
               end if;
            end;

         elsif Text (First .. Last) = "in"
           or else (Text (First .. Last) = "not"
                    and then Follows_With (Text, Scan, "in"))
         then
            --  "x not in y" writes its negation between the two sides
            --  rather than in front of the clause, which is the one
            --  place this grammar puts it there.
            if Text (First .. Last) = "not" then
               Denied_In := True;
               Read_Word (Text, Scan, First, Last);
            end if;

            --  Two questions share this word. "'role' in message" asks
            --  whether a message carries a field; "'x' in name" asks
            --  whether text occurs inside text. What follows the word
            --  is what tells them apart, and reading the right side as
            --  an operand is how the second one is answered.
            declare
               Ahead : Natural := Scan;
               Probe_First, Probe_Last : Natural;
            begin
               Read_Word (Text, Ahead, Probe_First, Probe_Last);
               if Probe_Last >= Probe_First
                 and then Text (Probe_First .. Probe_Last) = "message"
               then
                  From := Ahead;
                  Current.Operator := Compare_In_Message;
                  if Denied_In then
                     Current.Negated := not Current.Negated;
                  end if;
               else
                  From := Scan;
                  Read_Operand (Text, From, Current.Right, Taken);
                  if not Taken then
                     return;
                  end if;
                  Current.Operator :=
                    (if Denied_In then Compare_Not_In_Text
                     else Compare_In_Text);
               end if;
            end;

         else
            From := Restore;
         end if;
      end;
   end if;

   --  Every operator that has a right side reads one. The ordering
   --  ones were added beside the two equalities and this test was not
   --  widened with them, so a template comparing an order compiled as
   --  far as the operator and then refused for the rest of the line.
   if Current.Operator in Compare_Equal | Compare_Not_Equal
                        | Compare_Less | Compare_Less_Or_Equal
                        | Compare_Greater | Compare_Greater_Or_Equal
   then
      Read_Operand (Text, From, Current.Right, Taken);
      Ok := Taken;
   end if;
end Read_Test;
