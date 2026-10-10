package body Model_Runner.Tools.Python_Calls is

   --  Raised inside Read_Call where the text stops being a call it reads;
   --  never leaves it.
   Not_A_Call : exception;

   Max_Depth : constant := 32;

   ---------------
   -- Read_Call --
   ---------------

   procedure Read_Call
     (Text      : String;
      From      : in out Positive;
      Name      : out String;
      Name_Last : out Natural;
      Args      : out String;
      Args_Last : out Natural;
      Found     : out Boolean;
      Ok        : out Boolean;
      Offered   : access constant Definitions'Class := null)
   is
      P    : Natural := From;
      Used : Natural := 0;

      procedure Put (Item : String) is
      begin
         if Used + Item'Length > Args'Length then
            raise Not_A_Call;
         end if;
         Args (Args'First + Used .. Args'First + Used + Item'Length - 1) :=
           Item;
         Used := Used + Item'Length;
      end Put;

      function Here return Character
      is (if P <= Text'Last then Text (P) else ASCII.NUL);

      function Ahead (Mark : String) return Boolean
      is (P + Mark'Length - 1 <= Text'Last
          and then Text (P .. P + Mark'Length - 1) = Mark);

      --  Whitespace, comments and line breaks: a call may be written over
      --  several lines, as the Python it is.
      procedure Skip is
      begin
         while P <= Text'Last loop
            if Text (P) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR then
               P := P + 1;
            elsif Text (P) = '#' then
               while P <= Text'Last and then Text (P) /= ASCII.LF loop
                  P := P + 1;
               end loop;
            else
               exit;
            end if;
         end loop;
      end Skip;

      function Is_Start (C : Character) return Boolean
      is (C in 'a' .. 'z' | 'A' .. 'Z' | '_');

      function Is_Part (C : Character) return Boolean
      is (Is_Start (C) or else C in '0' .. '9');

      --  A name, and the slice of Text it is.
      procedure Word (First, Last : out Natural) is
      begin
         if not Is_Start (Here) then
            raise Not_A_Call;
         end if;
         First := P;
         while P <= Text'Last and then Is_Part (Text (P)) loop
            P := P + 1;
         end loop;
         Last := P - 1;
      end Word;

      --  One character of a string, as JSON writes it.
      procedure Put_Char (C : Character) is
         Hex : constant String := "0123456789abcdef";
      begin
         case C is
            when '"'      => Put ("\""");
            when '\'      => Put ("\\");
            when ASCII.LF => Put ("\n");
            when ASCII.CR => Put ("\r");
            when ASCII.HT => Put ("\t");
            when ASCII.NUL .. ASCII.BS | ASCII.VT | ASCII.FF
               | ASCII.SO .. ASCII.US =>
               Put ("\u00" & Hex (Character'Pos (C) / 16 + 1)
                    & Hex (Character'Pos (C) mod 16 + 1));
            when others   => Put ([1 => C]);
         end case;
      end Put_Char;

      function Is_Quote_Start return Boolean is
      begin
         if Here in '"' | ''' then
            return True;
         end if;
         --  A raw string's prefix.
         return Here in 'r' | 'R'
           and then P + 1 <= Text'Last
           and then Text (P + 1) in '"' | ''';
      end Is_Quote_Start;

      --  One string literal's characters, its quotes and escapes read, put
      --  without the JSON quotes around them.
      procedure String_Body is
         Raw   : Boolean := False;
         Quote : Character;
         Three : Boolean;
      begin
         if Here in 'r' | 'R' then
            Raw := True;
            P := P + 1;
         end if;
         Quote := Here;
         Three := Ahead ([1 .. 3 => Quote]);
         P := P + (if Three then 3 else 1);

         loop
            if P > Text'Last then
               raise Not_A_Call;
            end if;

            if Three and then Ahead ([1 .. 3 => Quote]) then
               P := P + 3;
               exit;
            elsif not Three and then Text (P) = Quote then
               P := P + 1;
               exit;
            elsif not Three and then Text (P) = ASCII.LF then
               raise Not_A_Call;
            elsif Text (P) = '\' and then not Raw and then P < Text'Last then
               declare
                  Next : constant Character := Text (P + 1);
               begin
                  P := P + 2;
                  case Next is
                     when 'n'      => Put ("\n");
                     when 't'      => Put ("\t");
                     when 'r'      => Put ("\r");
                     when '\'      => Put ("\\");
                     when '"'      => Put ("\""");
                     when '''      => Put ("'");
                     when '0'      => Put ("\u0000");
                     --  A line break escaped is a line continued.
                     when ASCII.LF => null;
                     when 'u'      =>
                        if P + 3 > Text'Last then
                           raise Not_A_Call;
                        end if;
                        for C of Text (P .. P + 3) loop
                           if C not in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' then
                              raise Not_A_Call;
                           end if;
                        end loop;
                        Put ("\u" & Text (P .. P + 3));
                        P := P + 4;
                     when 'x'      =>
                        if P + 1 > Text'Last then
                           raise Not_A_Call;
                        end if;
                        for C of Text (P .. P + 1) loop
                           if C not in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' then
                              raise Not_A_Call;
                           end if;
                        end loop;
                        Put ("\u00" & Text (P .. P + 1));
                        P := P + 2;
                     --  Python keeps an escape it does not know as it is
                     --  written, backslash and all.
                     when others   =>
                        Put ("\\");
                        Put_Char (Next);
                  end case;
               end;
            else
               Put_Char (Text (P));
               P := P + 1;
            end if;
         end loop;
      end String_Body;

      procedure Value (Depth : Natural);

      --  Items up to Closing, each a value, commas between and one allowed
      --  after the last, as Python allows.
      procedure Items (Closing : Character; Depth : Natural; Keyed : Boolean)
      is
         Count : Natural := 0;
      begin
         loop
            Skip;
            exit when Here = Closing;
            if Count > 0 then
               Put (",");
            end if;
            Count := Count + 1;

            if Keyed then
               if Is_Quote_Start then
                  Value (Depth + 1);
               elsif Here in '0' .. '9' | '-' then
                  --  A number as a key is the string of it in JSON.
                  Put ("""");
                  while Here in '0' .. '9' | '-' | '.' loop
                     Put ([1 => Here]);
                     P := P + 1;
                  end loop;
                  Put ("""");
               else
                  raise Not_A_Call;
               end if;
               Skip;
               if Here /= ':' then
                  raise Not_A_Call;
               end if;
               P := P + 1;
               Put (":");
               Skip;
            end if;

            Value (Depth + 1);
            Skip;
            if Here = ',' then
               P := P + 1;
            elsif Here /= Closing then
               raise Not_A_Call;
            end if;
         end loop;
         P := P + 1;
      end Items;

      procedure Value (Depth : Natural) is
      begin
         if Depth > Max_Depth then
            raise Not_A_Call;
         end if;
         Skip;

         if Is_Quote_Start then
            --  Strings standing side by side are one string in Python.
            Put ("""");
            loop
               String_Body;
               Skip;
               exit when not Is_Quote_Start;
            end loop;
            Put ("""");

         elsif Here = '[' or else Here = '(' then
            declare
               Closing : constant Character := (if Here = '[' then ']' else ')');
            begin
               P := P + 1;
               Put ("[");
               Items (Closing, Depth, Keyed => False);
               Put ("]");
            end;

         elsif Here = '{' then
            P := P + 1;
            Put ("{");
            Items ('}', Depth, Keyed => True);
            Put ("}");

         elsif Here in '0' .. '9' | '-' | '+' | '.' then
            declare
               Start   : constant Natural := P;
               Digits_Seen : Boolean := False;
            begin
               if Here = '-' then
                  Put ("-");
                  P := P + 1;
               elsif Here = '+' then
                  P := P + 1;
               end if;
               if Here = '.' then
                  Put ("0");
               end if;
               while P <= Text'Last
                 and then Text (P) in '0' .. '9' | '.' | 'e' | 'E' | '_'
                                    | '+' | '-'
               loop
                  if Text (P) in '0' .. '9' then
                     Digits_Seen := True;
                     Put ([1 => Text (P)]);
                  elsif Text (P) = '.' then
                     Put (".");
                     --  "1." is Python and not JSON: the zero it means.
                     if P = Text'Last or else Text (P + 1) not in '0' .. '9'
                     then
                        Put ("0");
                     end if;
                  elsif Text (P) in '+' | '-' then
                     --  A sign belongs to an exponent only.
                     exit when P = Start
                       or else Text (P - 1) not in 'e' | 'E';
                     Put ([1 => Text (P)]);
                  elsif Text (P) /= '_' then
                     Put ([1 => Text (P)]);
                  end if;
                  P := P + 1;
               end loop;
               if not Digits_Seen then
                  raise Not_A_Call;
               end if;
            end;

         elsif Is_Start (Here) then
            declare
               First, Last : Natural;
            begin
               Word (First, Last);
               declare
                  Said : constant String := Text (First .. Last);
               begin
                  if Said = "True" or else Said = "true" then
                     Put ("true");
                  elsif Said = "False" or else Said = "false" then
                     Put ("false");
                  elsif Said = "None" or else Said = "null" then
                     Put ("null");
                  else
                     raise Not_A_Call;
                  end if;
               end;
            end;

         else
            raise Not_A_Call;
         end if;
      end Value;

      --  The call's name, the last part of a dotted one.
      procedure Callee (First, Last : out Natural) is
      begin
         Word (First, Last);
         while Here = '.' loop
            P := P + 1;
            Word (First, Last);
         end loop;
      end Callee;

      --  The name of the parameter in a place of the called tool's, from
      --  the definitions offered; "" where none are, or it has none there.
      function Positional_Name (Called : String; Place : Positive) return String is
      begin
         if Offered = null then
            return "";
         end if;
         for Index in 1 .. Count (Offered.all) loop
            if Tool_Name (Offered.all, Index) = Called then
               return Parameter_At (Definition (Offered.all, Index), Place);
            end if;
         end loop;
         return "";
      end Positional_Name;

      First, Last : Natural;
      Wrapped     : Boolean := False;
      Keys        : Natural := 0;
      Keyed       : Boolean := False;
      Placed      : Natural := 0;
   begin
      Name_Last := 0;
      Args_Last := 0;
      Found     := False;
      Ok        := True;

      --  Statements may stand on lines of their own or apart by semicolons.
      loop
         Skip;
         exit when Here /= ';';
         P := P + 1;
      end loop;
      if P > Text'Last then
         From := Text'Last + 1;
         return;
      end if;
      --  The fence that closes the block: no call left in it.
      if Ahead ("```") then
         From := P;
         return;
      end if;
      Found := True;

      Callee (First, Last);
      Skip;
      if Here /= '(' then
         raise Not_A_Call;
      end if;
      P := P + 1;

      --  print(call(..)): the call inside.
      if Text (First .. Last) = "print" then
         Skip;
         Wrapped := True;
         Callee (First, Last);
         Skip;
         if Here /= '(' then
            raise Not_A_Call;
         end if;
         P := P + 1;
      end if;

      if Last - First + 1 > Name'Length then
         raise Not_A_Call;
      end if;
      Name (Name'First .. Name'First + Last - First) := Text (First .. Last);
      Name_Last := Last - First + 1;

      Put ("{");
      loop
         Skip;
         exit when Here = ')';
         declare
            Key_First, Key_Last : Natural;
            Arg_Start : constant Natural := P;
            Keyword   : Boolean := False;
         begin
            --  name=value, or a value alone: the parameter in its place.
            if Is_Start (Here) then
               Word (Key_First, Key_Last);
               Skip;
               Keyword := Here = '=' and then not Ahead ("==");
            end if;
            if Keyword then
               Keyed := True;
               P := P + 1;
               if Keys > 0 then
                  Put (",");
               end if;
               Keys := Keys + 1;
               Put ("""" & Text (Key_First .. Key_Last) & """:");
            else
               --  After a keyword none may stand alone, as in Python; and
               --  one is named by the definition, or the call is unread.
               P := Arg_Start;
               Placed := Placed + 1;
               declare
                  Called : constant String := Name (Name'First .. Name'First + Name_Last - 1);
                  Named  : constant String := Positional_Name (Called, Placed);
               begin
                  if Keyed or else Named = "" then
                     raise Not_A_Call;
                  end if;
                  if Keys > 0 then
                     Put (",");
                  end if;
                  Keys := Keys + 1;
                  Put ("""" & Named & """:");
               end;
            end if;
            Value (0);
            Skip;
            if Here = ',' then
               P := P + 1;
            elsif Here /= ')' then
               raise Not_A_Call;
            end if;
         end;
      end loop;
      P := P + 1;
      Put ("}");

      if Wrapped then
         Skip;
         if Here /= ')' then
            raise Not_A_Call;
         end if;
         P := P + 1;
      end if;

      Args_Last := Used;
      From := P;
   exception
      when Not_A_Call | Constraint_Error =>
         Ok        := False;
         Found     := True;
         Name_Last := 0;
         Args_Last := 0;
         From      := Text'Last + 1;
   end Read_Call;

   ------------------
   -- Parameter_At --
   ------------------

   function Parameter_At (Definition : String; Place : Positive) return String is
      Mark  : constant String := """properties""";
      P     : Natural := Definition'First;
      Depth : Natural := 0;
      Seen  : Natural := 0;

      --  Past the string that opens at P.
      procedure Over_String is
      begin
         P := P + 1;
         while P <= Definition'Last and then Definition (P) /= '"' loop
            if Definition (P) = '\' then
               P := P + 1;
            end if;
            P := P + 1;
         end loop;
         P := P + 1;
      end Over_String;
   begin
      --  The properties object.
      loop
         if P + Mark'Length - 1 > Definition'Last then
            return "";
         end if;
         exit when Definition (P .. P + Mark'Length - 1) = Mark;
         P := P + 1;
      end loop;
      P := P + Mark'Length;
      while P <= Definition'Last and then Definition (P) /= '{' loop
         P := P + 1;
      end loop;
      P := P + 1;

      --  Its keys at its own depth, in order.
      while P <= Definition'Last loop
         case Definition (P) is
            when '"' =>
               if Depth = 0 then
                  declare
                     Key_First : constant Positive := P + 1;
                  begin
                     Over_String;
                     Seen := Seen + 1;
                     if Seen = Place then
                        return Definition (Key_First .. P - 2);
                     end if;
                  end;
               else
                  Over_String;
               end if;
            when '{' | '[' =>
               Depth := Depth + 1;
               P := P + 1;
            when '}' | ']' =>
               exit when Depth = 0;
               Depth := Depth - 1;
               P := P + 1;
            when others =>
               P := P + 1;
         end case;
      end loop;
      return "";
   end Parameter_At;

end Model_Runner.Tools.Python_Calls;
