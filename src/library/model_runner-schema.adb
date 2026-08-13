package body Model_Runner.Schema is

   package E renames Model_Runner.Errors;

   --  A reader over the schema text.
   --
   --  Enough JSON to read a schema and no more: objects, arrays, strings,
   --  numbers, the three literals. It never allocates and never raises; a
   --  text it cannot read is a position it reports.
   type Reader is record
      At_Char : Natural := 0;
      Failed  : Boolean := False;
      Where   : Natural := 0;
   end record;

   procedure Skip_Blanks (Text : String; Item : in out Reader) is
   begin
      while Item.At_Char <= Text'Last
        and then (Text (Item.At_Char) = ' '
                  or else Text (Item.At_Char) = Character'Val (9)
                  or else Text (Item.At_Char) = Character'Val (10)
                  or else Text (Item.At_Char) = Character'Val (13))
      loop
         Item.At_Char := Item.At_Char + 1;
      end loop;
   end Skip_Blanks;

   procedure Fail (Item : in out Reader) is
   begin
      if not Item.Failed then
         Item.Failed := True;
         Item.Where := Item.At_Char;
      end if;
   end Fail;

   --  Read a quoted string, giving back where its contents are. The bounds
   --  are into the schema text, so nothing is copied.
   procedure Read_String
     (Text  : String;
      Item  : in out Reader;
      First : out Natural;
      Last  : out Natural)
   is
   begin
      First := 1;
      Last := 0;

      Skip_Blanks (Text, Item);
      if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '"' then
         Fail (Item);
         return;
      end if;

      Item.At_Char := Item.At_Char + 1;
      First := Item.At_Char;

      while Item.At_Char <= Text'Last and then Text (Item.At_Char) /= '"' loop
         --  An escape takes the next character with it, so that a quote
         --  inside a string does not end it.
         if Text (Item.At_Char) = '\' then
            Item.At_Char := Item.At_Char + 1;
         end if;
         Item.At_Char := Item.At_Char + 1;
      end loop;

      if Item.At_Char > Text'Last then
         Fail (Item);
         return;
      end if;

      Last := Item.At_Char - 1;
      Item.At_Char := Item.At_Char + 1;
   end Read_String;

   --  Where a value begins and ends, whatever kind it is. Used for the
   --  literals of enum and const, which are written into the grammar exactly
   --  as the schema wrote them.
   procedure Read_Value
     (Text  : String;
      Item  : in out Reader;
      First : out Natural;
      Last  : out Natural;
      Depth : Natural := 0)
   is
      Opened : Natural := 0;
   begin
      First := 1;
      Last := 0;

      if Depth > Max_Depth then
         Fail (Item);
         return;
      end if;

      Skip_Blanks (Text, Item);
      if Item.At_Char > Text'Last then
         Fail (Item);
         return;
      end if;

      First := Item.At_Char;

      case Text (Item.At_Char) is
         when '"' =>
            declare
               Ignored_First, Ignored_Last : Natural;
            begin
               Read_String (Text, Item, Ignored_First, Ignored_Last);
            end;

         when '{' | '[' =>
            --  Balanced, counting only brackets outside strings.
            loop
               if Item.At_Char > Text'Last then
                  Fail (Item);
                  return;
               end if;

               case Text (Item.At_Char) is
                  when '{' | '[' =>
                     Opened := Opened + 1;
                     Item.At_Char := Item.At_Char + 1;

                  when '}' | ']' =>
                     Opened := Opened - 1;
                     Item.At_Char := Item.At_Char + 1;
                     exit when Opened = 0;

                  when '"' =>
                     declare
                        Ignored_First, Ignored_Last : Natural;
                     begin
                        Read_String (Text, Item, Ignored_First, Ignored_Last);
                        exit when Item.Failed;
                     end;

                  when others =>
                     Item.At_Char := Item.At_Char + 1;
               end case;
            end loop;

         when others =>
            --  A number or one of the three literals: everything up to the
            --  next separator.
            while Item.At_Char <= Text'Last
              and then Text (Item.At_Char) /= ','
              and then Text (Item.At_Char) /= '}'
              and then Text (Item.At_Char) /= ']'
              and then Text (Item.At_Char) /= ' '
              and then Text (Item.At_Char) /= Character'Val (9)
              and then Text (Item.At_Char) /= Character'Val (10)
              and then Text (Item.At_Char) /= Character'Val (13)
            loop
               Item.At_Char := Item.At_Char + 1;
            end loop;
      end case;

      Last := Item.At_Char - 1;
      if Last < First then
         Fail (Item);
      end if;
   end Read_Value;

   --  Find a member of the object beginning at From, and say where its value
   --  begins. Zero when the object has no such member.
   procedure Find_Member
     (Text  : String;
      From  : Natural;
      Name  : String;
      At_Value : out Natural;
      Failed   : out Boolean)
   is
      Item : Reader := (At_Char => From, others => <>);
   begin
      At_Value := 0;
      Failed := False;

      Skip_Blanks (Text, Item);
      if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '{' then
         Failed := True;
         return;
      end if;
      Item.At_Char := Item.At_Char + 1;

      loop
         Skip_Blanks (Text, Item);
         exit when Item.At_Char > Text'Last;

         if Text (Item.At_Char) = '}' then
            return;
         end if;

         declare
            Key_First, Key_Last : Natural;
            Value_First, Value_Last : Natural;
         begin
            Read_String (Text, Item, Key_First, Key_Last);
            if Item.Failed then
               Failed := True;
               return;
            end if;

            Skip_Blanks (Text, Item);
            if Item.At_Char > Text'Last or else Text (Item.At_Char) /= ':' then
               Failed := True;
               return;
            end if;
            Item.At_Char := Item.At_Char + 1;

            Skip_Blanks (Text, Item);
            Value_First := Item.At_Char;

            Read_Value (Text, Item, Value_First, Value_Last);
            if Item.Failed then
               Failed := True;
               return;
            end if;

            if Text (Key_First .. Key_Last) = Name then
               At_Value := Value_First;
               return;
            end if;

            Skip_Blanks (Text, Item);
            if Item.At_Char <= Text'Last
              and then Text (Item.At_Char) = ','
            then
               Item.At_Char := Item.At_Char + 1;
            end if;
         end;
      end loop;

      Failed := True;
   end Find_Member;

   ------------------
   -- To_Grammar --
   ------------------

   procedure To_Grammar
     (Text    : String;
      Grammar : out String;
      Last    : out Natural;
      Status  : out E.Error_Info)
   is
      Used : Natural := 0;

      Overflowed : Boolean := False;

      procedure Put (Item : String) is
      begin
         if Used + Item'Length > Grammar'Length then
            Overflowed := True;
            return;
         end if;

         Grammar (Grammar'First + Used
                  .. Grammar'First + Used + Item'Length - 1) := Item;
         Used := Used + Item'Length;
      end Put;

      Refused : Boolean := False;
      Refused_By : String (1 .. 64) := [others => ' '];
      Refused_Up : Natural := 0;

      procedure Refuse (What : String) is
         Room : constant Natural :=
           Natural'Min (What'Length, Refused_By'Length);
      begin
         if not Refused then
            Refused := True;
            Refused_By (1 .. Room) :=
              What (What'First .. What'First + Room - 1);
            Refused_Up := Room;
         end if;
      end Refuse;

      Malformed : Boolean := False;

      --  Write the grammar for the schema whose object begins at From.
      procedure Shape (From : Natural; Depth : Natural);

      --  The type keyword's value, as a bare word. Empty when absent.
      procedure Named_Type
        (From  : Natural;
         First : out Natural;
         Last  : out Natural)
      is
         At_Value : Natural;
         Failed   : Boolean;
         Item     : Reader;
      begin
         First := 1;
         Last := 0;

         Find_Member (Text, From, "type", At_Value, Failed);
         if Failed or else At_Value = 0 then
            return;
         end if;

         Item := (At_Char => At_Value, others => <>);
         Read_String (Text, Item, First, Last);
         if Item.Failed then
            First := 1;
            Last := 0;
         end if;
      end Named_Type;

      --  One of the plain types, as a grammar fragment.
      procedure Plain (Word : String) is
      begin
         if Word = "string" then
            Put ("str");
         elsif Word = "number" then
            Put ("num");
         elsif Word = "integer" then
            Put ("int");
         elsif Word = "boolean" then
            Put ("bool");
         elsif Word = "null" then
            Put ("""null""");
         else
            Refuse (Word);
         end if;
      end Plain;

      --  An object: exactly the properties named, in the order named.
      procedure Object_Shape (From : Natural; Depth : Natural) is
         At_Props : Natural;
         Failed   : Boolean;
         Item     : Reader;
         Count    : Natural := 0;
      begin
         Find_Member (Text, From, "properties", At_Props, Failed);
         if Failed or else At_Props = 0 then
            --  An object with no properties named is any object, which this
            --  cannot write without allowing everything.
            Refuse ("object without properties");
            return;
         end if;

         Put ("""{"" ");

         Item := (At_Char => At_Props, others => <>);
         Skip_Blanks (Text, Item);
         if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '{' then
            Malformed := True;
            return;
         end if;
         Item.At_Char := Item.At_Char + 1;

         loop
            Skip_Blanks (Text, Item);
            exit when Item.At_Char > Text'Last;
            exit when Text (Item.At_Char) = '}';

            declare
               Key_First, Key_Last     : Natural;
               Value_First, Value_Last : Natural;
            begin
               Read_String (Text, Item, Key_First, Key_Last);
               if Item.Failed then
                  Malformed := True;
                  return;
               end if;

               Skip_Blanks (Text, Item);
               if Item.At_Char > Text'Last
                 or else Text (Item.At_Char) /= ':'
               then
                  Malformed := True;
                  return;
               end if;
               Item.At_Char := Item.At_Char + 1;

               Skip_Blanks (Text, Item);
               Value_First := Item.At_Char;
               Read_Value (Text, Item, Value_First, Value_Last);
               if Item.Failed then
                  Malformed := True;
                  return;
               end if;

               if Count > 0 then
                  Put (" "","" ");
               end if;
               Count := Count + 1;

               Put ("""\""");
               Put (Text (Key_First .. Key_Last));
               Put ("\"":"" ");
               Shape (Value_First, Depth + 1);

               Skip_Blanks (Text, Item);
               if Item.At_Char <= Text'Last
                 and then Text (Item.At_Char) = ','
               then
                  Item.At_Char := Item.At_Char + 1;
               end if;
            end;
         end loop;

         Put (" ""}""");
      end Object_Shape;

      procedure Array_Shape (From : Natural; Depth : Natural) is
         At_Items : Natural;
         Failed   : Boolean;
      begin
         Find_Member (Text, From, "items", At_Items, Failed);
         if Failed or else At_Items = 0 then
            Refuse ("array without items");
            return;
         end if;

         --  Empty, one, or several separated by commas.
         Put ("""["" (");
         Shape (At_Items, Depth + 1);
         Put (" ("","" ");
         Shape (At_Items, Depth + 1);
         Put (")*)? ""]""");
      end Array_Shape;

      --  A list of literal values, as alternatives written exactly as the
      --  schema wrote them.
      procedure Choice (At_Value : Natural) is
         Item  : Reader := (At_Char => At_Value, others => <>);
         Count : Natural := 0;
      begin
         Skip_Blanks (Text, Item);
         if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '[' then
            Malformed := True;
            return;
         end if;
         Item.At_Char := Item.At_Char + 1;

         Put ("(");

         loop
            Skip_Blanks (Text, Item);
            exit when Item.At_Char > Text'Last;
            exit when Text (Item.At_Char) = ']';

            declare
               First, Last_At : Natural;
            begin
               Read_Value (Text, Item, First, Last_At);
               if Item.Failed then
                  Malformed := True;
                  return;
               end if;

               if Count > 0 then
                  Put (" | ");
               end if;
               Count := Count + 1;

               --  Written as a literal, with the quotes a JSON string
               --  carries escaped so the grammar reads them as text.
               Put ("""");
               for Index in First .. Last_At loop
                  if Text (Index) = '"' then
                     Put ("\""");
                  else
                     Put (Text (Index .. Index));
                  end if;
               end loop;
               Put ("""");

               Skip_Blanks (Text, Item);
               if Item.At_Char <= Text'Last
                 and then Text (Item.At_Char) = ','
               then
                  Item.At_Char := Item.At_Char + 1;
               end if;
            end;
         end loop;

         Put (")");

         if Count = 0 then
            Malformed := True;
         end if;
      end Choice;

      --  Every member of a schema object, checked against what this reads.
      --  A keyword it does not read is refused rather than ignored: ignoring
      --  one produces a grammar that allows more than the schema does, which
      --  is a constraint that quietly is not one.
      procedure Known_Keywords (From : Natural) is
         Item : Reader := (At_Char => From, others => <>);
      begin
         Skip_Blanks (Text, Item);
         if Item.At_Char > Text'Last or else Text (Item.At_Char) /= '{' then
            return;
         end if;
         Item.At_Char := Item.At_Char + 1;

         loop
            Skip_Blanks (Text, Item);
            exit when Item.At_Char > Text'Last;
            exit when Text (Item.At_Char) = '}';

            declare
               Key_First, Key_Last : Natural;
               Value_First, Value_Last : Natural;
            begin
               Read_String (Text, Item, Key_First, Key_Last);
               exit when Item.Failed;

               Skip_Blanks (Text, Item);
               exit when Item.At_Char > Text'Last
                 or else Text (Item.At_Char) /= ':';
               Item.At_Char := Item.At_Char + 1;

               Read_Value (Text, Item, Value_First, Value_Last);
               exit when Item.Failed;

               declare
                  Word : constant String := Text (Key_First .. Key_Last);
               begin
                  if Word /= "type" and then Word /= "properties"
                    and then Word /= "required" and then Word /= "items"
                    and then Word /= "enum" and then Word /= "const"
                    --  Documentary keywords say nothing about the shape.
                    and then Word /= "description" and then Word /= "title"
                    and then Word /= "$schema" and then Word /= "$id"
                  then
                     Refuse (Word);
                     return;
                  end if;
               end;

               Skip_Blanks (Text, Item);
               if Item.At_Char <= Text'Last
                 and then Text (Item.At_Char) = ','
               then
                  Item.At_Char := Item.At_Char + 1;
               end if;
            end;
         end loop;
      end Known_Keywords;

      procedure Shape (From : Natural; Depth : Natural) is
         At_Enum, At_Const : Natural;
         Failed : Boolean;

         Type_First, Type_Last : Natural;
      begin
         Known_Keywords (From);
         if Refused then
            return;
         end if;

         if Depth > Max_Depth then
            Refuse ("nesting");
            return;
         end if;

         --  A fixed value, or a choice between fixed values, says everything
         --  and nothing else needs reading.
         Find_Member (Text, From, "const", At_Const, Failed);
         if not Failed and then At_Const /= 0 then
            declare
               Item : Reader := (At_Char => At_Const, others => <>);
               First, Last_At : Natural;
            begin
               Read_Value (Text, Item, First, Last_At);
               if Item.Failed then
                  Malformed := True;
                  return;
               end if;

               Put ("""");
               for Index in First .. Last_At loop
                  if Text (Index) = '"' then
                     Put ("\""");
                  else
                     Put (Text (Index .. Index));
                  end if;
               end loop;
               Put ("""");
            end;
            return;
         end if;

         Find_Member (Text, From, "enum", At_Enum, Failed);
         if not Failed and then At_Enum /= 0 then
            Choice (At_Enum);
            return;
         end if;

         Named_Type (From, Type_First, Type_Last);
         if Type_Last < Type_First then
            Refuse ("a schema with no type, const or enum");
            return;
         end if;

         declare
            Word : constant String := Text (Type_First .. Type_Last);
         begin
            if Word = "object" then
               Object_Shape (From, Depth);
            elsif Word = "array" then
               Array_Shape (From, Depth);
            else
               Plain (Word);
            end if;
         end;
      end Shape;
   begin
      Grammar := [others => ' '];
      Last := 0;
      Status := E.Success;

      if Text'Length = 0 or else Text'Length > Max_Schema_Bytes then
         Status := E.Make (E.Grammar_Syntax_Error);
         E.Add_Text (Status, "construct", "the schema", E.Param_Identifier);
         return;
      end if;

      Put ("root ::= ");
      Shape (Text'First, 0);
      Put (Character'Val (10) & "");

      --  The pieces every schema leans on, written once. A grammar that
      --  names a rule it does not define is refused by the compiler, so
      --  these are always here even when nothing used them.
      Put ("str ::= ""\"""" (safe | esc)* ""\"""""
           & Character'Val (10));
      --  Everything but a quote, a backslash and the control characters,
      --  which JSON says a string may not carry raw. Without that range a
      --  model can put a newline inside a string and the grammar allows it,
      --  which is a constraint that produces text no JSON reader accepts.
      Put ("safe ::= [^\""\\\x00-\x1f]" & Character'Val (10));
      Put ("esc ::= ""\\"" ([\""\\/bfnrt] | ""u"" hex hex hex hex)"
           & Character'Val (10));
      Put ("hex ::= [0-9a-fA-F]" & Character'Val (10));
      Put ("int ::= ""-""? [0-9]+" & Character'Val (10));
      Put ("num ::= ""-""? [0-9]+ (""."" [0-9]+)? "
           & "([eE] [-+]? [0-9]+)?" & Character'Val (10));
      Put ("bool ::= ""true"" | ""false""" & Character'Val (10));

      if Malformed then
         Status := E.Make (E.Grammar_Syntax_Error);
         E.Add_Text (Status, "construct", "the schema", E.Param_Identifier);
         return;
      end if;

      if Refused then
         Status := E.Make (E.Grammar_Schema_Unsupported);
         E.Add_Text
           (Status, "construct", Refused_By (1 .. Refused_Up),
            E.Param_Identifier);
         return;
      end if;

      if Overflowed then
         Status := E.Make (E.Grammar_Too_Large);
         return;
      end if;

      Last := Used;
   end To_Grammar;

end Model_Runner.Schema;
