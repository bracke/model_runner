with Ada.Strings.Fixed;

package body Measurement_Publications is

   function Device_Table_Consistent (Table, Ledger : String) return Boolean is
      Heading : constant String := "### The device backend";
      Groups : Natural := 0;
      Figures : Natural := 0;
      Found : Boolean := False;
      Inside : Boolean := False;
      Good : Boolean := True;

      function Numeric_Part (Ch : Character) return Boolean
      is (Ch in '0' .. '9' | '.' | 'A' .. 'Z' | 'a' .. 'z' | '_');

      function Recorded (Value : String) return Boolean is
         From : Positive := Ledger'First;
      begin
         while From <= Ledger'Last loop
            declare
               At_Value : constant Natural := Ada.Strings.Fixed.Index (Ledger, Value, From);
            begin
               if At_Value = 0 then
                  return False;
               elsif (At_Value = Ledger'First or else not Numeric_Part (Ledger (At_Value - 1)))
                 and then (At_Value + Value'Length > Ledger'Last
                           or else not Numeric_Part (Ledger (At_Value + Value'Length)))
               then
                  return True;
               end if;
               From := At_Value + 1;
            end;
         end loop;
         return False;
      end Recorded;

      procedure Line (Text : String; Registry : Boolean) is
         Last : Natural := Text'Last;
      begin
         if Text'Length > 0 and then Text (Last) = ASCII.CR then
            Last := Last - 1;
         end if;
         declare
            Item : constant String := Text (Text'First .. Last);
         begin
            if Registry then
               if Item'Length >= 7 and then Item (Item'First .. Item'First + 6) = "device " then
                  Groups := Groups + 1;
               end if;
            elsif Item = Heading then
               Good := Good and then not Found;
               Found := True;
               Inside := True;
            elsif Item'Length > 0 and then Item (Item'First) = '#' then
               Inside := False;
            elsif Inside and then Item'Length > 0 and then Item (Item'First) = '|' then
               declare
                  At_Number : Natural := Item'First;
               begin
                  while At_Number <= Item'Last loop
                     if Item (At_Number) in '0' .. '9' then
                        declare
                           Stop : Natural := At_Number;
                           Points : Natural := 0;
                        begin
                           while Stop <= Item'Last and then Item (Stop) in '0' .. '9' | '.' loop
                              if Item (Stop) = '.' then
                                 Points := Points + 1;
                              end if;
                              Stop := Stop + 1;
                           end loop;
                           if Stop + 1 <= Item'Last and then Item (Stop .. Stop + 1) = " s" then
                              Figures := Figures + 1;
                              Good := Good and then Points <= 1
                                and then Recorded (Item (At_Number .. Stop - 1));
                           end if;
                           At_Number := Stop;
                        end;
                     else
                        At_Number := At_Number + 1;
                     end if;
                  end loop;
               end;
            end if;
         end;
      end Line;

      procedure Scan (Text : String; Registry : Boolean) is
         From : Positive := Text'First;
      begin
         for Index in Text'Range loop
            if Text (Index) = ASCII.LF then
               Line (Text (From .. Index - 1), Registry);
               From := Index + 1;
            end if;
         end loop;
         if From <= Text'Last then
            Line (Text (From .. Text'Last), Registry);
         end if;
      end Scan;
   begin
      Scan (Ledger, Registry => True);
      Scan (Table, Registry => False);
      return Found and then Good
        and then ((Groups = 0 and then Figures = 0) or else (Groups = 1 and then Figures > 0));
   end Device_Table_Consistent;

end Measurement_Publications;
