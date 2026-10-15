with Ada.Characters.Handling;

with Model_Runner.UTF8;

package body Model_Runner.Grammar is

   package E renames Model_Runner.Errors;

   --  Elements one alternative-list may hold while it is being parsed.
   --
   --  A group and a repetition become rules of their own, so nesting costs a
   --  frame rather than room here, and one alternative-list is as long as the
   --  text a person writes on one line of a grammar.
   Max_Pending : constant := 512;

   --  How deep grouping may nest while parsing, which bounds the recursion
   --  below and therefore the stack this uses.
   Max_Parse_Depth : constant := 24;

   type Pending is array (1 .. Max_Pending) of Element;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Compiled) is
   begin
      Item.Ready := False;
   end Finalize;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Compiled) is
   begin
      Item.Ready := False;
      Item.Rule_Used := 0;
      Item.Element_Used := 0;
      Item.Range_Used := 0;
      Item.Name_Used := 0;
      Item.Root := 0;
   end Close;

   --------------
   -- Is_Ready --
   --------------

   function Is_Ready (Item : Compiled) return Boolean is (Item.Ready);

   ---------------------------------------------------------------------------
   --  Compilation
   ---------------------------------------------------------------------------

   procedure Compile
     (Item   : in out Compiled;
      Source : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      At_Byte : Natural := Source'First;

      --  The rules a star made -- R ::= x R | -- and where in the source:
      --  a repeat of something that can match nothing is refused once every
      --  rule is known, as llama.cpp refuses the left recursion it is.
      Is_Star     : array (1 .. Max_Rules) of Boolean := [others => False];
      Star_Offset : array (1 .. Max_Rules) of Natural := [others => 0];

      --  Report a diagnostic naming where it happened. The position is
      --  reported rather than the character, because a grammar may hold
      --  bytes that have no business on a terminal.
      procedure Fail (Code : E.Error_Code; What : String) is
      begin
         Status := E.Make (Code);
         E.Add_Text (Status, "construct", What, E.Param_Text);
         E.Add_Integer
           (Status, "offset", Long_Long_Integer (At_Byte - Source'First),
            E.Param_Offset);
      end Fail;

      function Done return Boolean is (At_Byte > Source'Last);

      function Peek return Character
      is (if Done then Character'Val (0) else Source (At_Byte));

      --  Whitespace and comments, which may appear anywhere a token may.
      procedure Skip_Blanks is
      begin
         loop
            while not Done
              and then Peek in ' ' | Character'Val (9) | Character'Val (10)
                             | Character'Val (13)
            loop
               At_Byte := At_Byte + 1;
            end loop;

            exit when Done or else Peek /= '#';

            while not Done and then Peek /= Character'Val (10) loop
               At_Byte := At_Byte + 1;
            end loop;
         end loop;
      end Skip_Blanks;

      function Is_Name_Char (Item : Character) return Boolean
      is (Ada.Characters.Handling.Is_Alphanumeric (Item)
          or else Item = '-' or else Item = '_');

      --  Find a rule by name, defining it if it is not there yet. A rule may
      --  be referred to before it is written, which is what lets a grammar
      --  be recursive at all.
      procedure Named (Text : String; Index : out Natural; Ok : out Boolean) is
      begin
         Ok := True;

         for Which in 1 .. Item.Rule_Used loop
            declare
               First : constant Natural := Item.Rules (Which).Name_First;
               Last  : constant Natural := Item.Rules (Which).Name_Last;
            begin
               if Last >= First
                 and then Item.Names (First .. Last) = Text
               then
                  Index := Which;
                  return;
               end if;
            end;
         end loop;

         if Item.Rule_Used = Max_Rules
           or else Item.Name_Used + Text'Length > Max_Names
         then
            Index := 0;
            Ok := False;
            return;
         end if;

         Item.Rule_Used := Item.Rule_Used + 1;
         Index := Item.Rule_Used;
         Item.Names (Item.Name_Used + 1 .. Item.Name_Used + Text'Length) :=
           Text;
         Item.Rules (Index) :=
           (Start      => 0,
            Name_First => Item.Name_Used + 1,
            Name_Last  => Item.Name_Used + Text'Length);
         Item.Name_Used := Item.Name_Used + Text'Length;
      end Named;

      --  A rule with no name, for a group or a repetition. Nothing can refer
      --  to it by name and nothing needs to.
      procedure Anonymous (Index : out Natural; Ok : out Boolean) is
      begin
         if Item.Rule_Used = Max_Rules then
            Index := 0;
            Ok := False;
            return;
         end if;

         Item.Rule_Used := Item.Rule_Used + 1;
         Index := Item.Rule_Used;
         Item.Rules (Index) := (Start => 0, Name_First => 1, Name_Last => 0);
         Ok := True;
      end Anonymous;

      --  Move a parsed alternative-list into the rule table.
      procedure Commit
        (Rule : Natural; Body_Of : Pending; Used : Natural; Ok : out Boolean)
      is
      begin
         if Item.Element_Used + Used + 1 > Max_Elements then
            Ok := False;
            return;
         end if;

         Item.Rules (Rule).Start := Item.Element_Used + 1;
         for Index in 1 .. Used loop
            Item.Elements (Item.Element_Used + Index) := Body_Of (Index);
         end loop;
         Item.Element_Used := Item.Element_Used + Used;

         Item.Element_Used := Item.Element_Used + 1;
         Item.Elements (Item.Element_Used) := (Kind => Element_End, others => <>);
         Ok := True;
      end Commit;

      --  Parse one alternative-list into Room, which is what a rule body,
      --  a group and a repetition are all made of.
      procedure Alternatives
        (Room  : out Pending;
         Used  : out Natural;
         Depth : Natural;
         Ok    : out Boolean);

      --  One code-point set, either bracketed or a literal's character.
      procedure Add_Range
        (Low, High : Code_Point; First : in out Natural; Count : in out Natural;
         Ok        : out Boolean) is
      begin
         if Item.Range_Used = Max_Ranges then
            Ok := False;
            return;
         end if;

         Item.Range_Used := Item.Range_Used + 1;
         Item.Ranges (Item.Range_Used) := (Low => Low, High => High);
         if Count = 0 then
            First := Item.Range_Used;
         end if;
         Count := Count + 1;
         Ok := True;
      end Add_Range;

      --  An escape, or the code point that is simply there.
      procedure Next_Code_Point (Value : out Code_Point; Ok : out Boolean) is
         Digits_Wanted : Natural := 0;
         Number        : Natural := 0;
      begin
         Ok := True;
         Value := 0;

         if Done then
            Ok := False;
            return;
         end if;

         if Peek /= '\' then
            declare
               Point  : Natural;
               Length : Natural;
            begin
               Model_Runner.UTF8.Decode_First
                 (Source (At_Byte .. Source'Last), Point, Length);
               if Length = 0 then
                  Ok := False;
                  return;
               end if;
               Value := Code_Point (Point);
               At_Byte := At_Byte + Length;
               return;
            end;
         end if;

         At_Byte := At_Byte + 1;
         if Done then
            Ok := False;
            return;
         end if;

         case Peek is
            when 'n' => Value := 10; At_Byte := At_Byte + 1; return;
            when 'r' => Value := 13; At_Byte := At_Byte + 1; return;
            when 't' => Value := 9;  At_Byte := At_Byte + 1; return;
            when '\' | '"' | ''' | '[' | ']' =>
               Value := Code_Point (Character'Pos (Peek));
               At_Byte := At_Byte + 1;
               return;
            when 'x' => Digits_Wanted := 2;
            when 'u' => Digits_Wanted := 4;
            when 'U' => Digits_Wanted := 8;
            when others =>
               Ok := False;
               return;
         end case;

         At_Byte := At_Byte + 1;
         for Each in 1 .. Digits_Wanted loop
            if Done or else not Ada.Characters.Handling.Is_Hexadecimal_Digit
                                  (Peek)
            then
               Ok := False;
               return;
            end if;

            Number := Number * 16
              + (if Peek in '0' .. '9'
                 then Character'Pos (Peek) - Character'Pos ('0')
                 elsif Peek in 'a' .. 'f'
                 then Character'Pos (Peek) - Character'Pos ('a') + 10
                 else Character'Pos (Peek) - Character'Pos ('A') + 10);
            At_Byte := At_Byte + 1;
         end loop;

         if Number > Natural (Code_Point'Last) then
            Ok := False;
            return;
         end if;

         Value := Code_Point (Number);
      end Next_Code_Point;

      --  Parse one item and leave exactly one element in Room. Everything
      --  that is not a single element -- a group, a repetition -- becomes a
      --  rule of its own and leaves a reference to it, which is what makes
      --  a postfix apply to exactly one element.
      procedure One_Item
        (Result : out Element;
         Depth  : Natural;
         Ok     : out Boolean)
      is
      begin
         Result := (Kind => Element_End, others => <>);
         Ok := True;

         if Done then
            Fail (E.Grammar_Syntax_Error, "end of grammar");
            Ok := False;
            return;
         end if;

         case Peek is
            when '"' | ''' =>
               --  A literal is a sequence of one-code-point sets, so it
               --  cannot be one element. It becomes a rule.
               declare
                  Quote : constant Character := Peek;
                  Room  : Pending;
                  Used  : Natural := 0;
                  Rule  : Natural;
                  Good  : Boolean;
               begin
                  At_Byte := At_Byte + 1;

                  while not Done and then Peek /= Quote loop
                     declare
                        Value : Code_Point;
                        First : Natural := 0;
                        Count : Natural := 0;
                     begin
                        Next_Code_Point (Value, Good);
                        if not Good then
                           Fail (E.Grammar_Syntax_Error, "escape");
                           Ok := False;
                           return;
                        end if;

                        Add_Range (Value, Value, First, Count, Good);
                        if not Good then
                           Fail (E.Grammar_Too_Large, "ranges");
                           Ok := False;
                           return;
                        end if;

                        if Used = Max_Pending then
                           Fail (E.Grammar_Too_Large, "literal");
                           Ok := False;
                           return;
                        end if;

                        Used := Used + 1;
                        Room (Used) :=
                          (Kind => Element_Char, First => First,
                           Count => Count, Inverted => False, Rule => 0);
                     end;
                  end loop;

                  if Done then
                     Fail (E.Grammar_Syntax_Error, "unterminated literal");
                     Ok := False;
                     return;
                  end if;
                  At_Byte := At_Byte + 1;

                  Anonymous (Rule, Good);
                  if not Good then
                     Fail (E.Grammar_Too_Large, "rules");
                     Ok := False;
                     return;
                  end if;

                  Commit (Rule, Room, Used, Good);
                  if not Good then
                     Fail (E.Grammar_Too_Large, "elements");
                     Ok := False;
                     return;
                  end if;

                  Result :=
                    (Kind => Element_Reference, First => 0, Count => 0,
                     Inverted => False, Rule => Rule);
               end;

            when '[' =>
               declare
                  First    : Natural := 0;
                  Count    : Natural := 0;
                  Inverted : Boolean := False;
                  Good     : Boolean;
               begin
                  At_Byte := At_Byte + 1;
                  if not Done and then Peek = '^' then
                     Inverted := True;
                     At_Byte := At_Byte + 1;
                  end if;

                  while not Done and then Peek /= ']' loop
                     declare
                        Low, High : Code_Point;
                     begin
                        Next_Code_Point (Low, Good);
                        if not Good then
                           Fail (E.Grammar_Syntax_Error, "set");
                           Ok := False;
                           return;
                        end if;

                        High := Low;
                        if not Done and then Peek = '-'
                          and then At_Byte < Source'Last
                          and then Source (At_Byte + 1) /= ']'
                        then
                           At_Byte := At_Byte + 1;
                           Next_Code_Point (High, Good);
                           if not Good or else High < Low then
                              Fail (E.Grammar_Syntax_Error, "range");
                              Ok := False;
                              return;
                           end if;
                        end if;

                        Add_Range (Low, High, First, Count, Good);
                        if not Good then
                           Fail (E.Grammar_Too_Large, "ranges");
                           Ok := False;
                           return;
                        end if;
                     end;
                  end loop;

                  if Done or else Count = 0 then
                     Fail (E.Grammar_Syntax_Error, "unterminated set");
                     Ok := False;
                     return;
                  end if;
                  At_Byte := At_Byte + 1;

                  Result :=
                    (Kind => Element_Char, First => First, Count => Count,
                     Inverted => Inverted, Rule => 0);
               end;

            when '(' =>
               declare
                  Room : Pending;
                  Used : Natural := 0;
                  Rule : Natural;
                  Good : Boolean;
               begin
                  if Depth >= Max_Parse_Depth then
                     Fail (E.Grammar_Nesting_Too_Deep, "group");
                     Ok := False;
                     return;
                  end if;

                  At_Byte := At_Byte + 1;
                  Alternatives (Room, Used, Depth + 1, Good);
                  if not Good then
                     Ok := False;
                     return;
                  end if;

                  Skip_Blanks;
                  if Done or else Peek /= ')' then
                     Fail (E.Grammar_Syntax_Error, "unclosed group");
                     Ok := False;
                     return;
                  end if;
                  At_Byte := At_Byte + 1;

                  Anonymous (Rule, Good);
                  if not Good then
                     Fail (E.Grammar_Too_Large, "rules");
                     Ok := False;
                     return;
                  end if;

                  Commit (Rule, Room, Used, Good);
                  if not Good then
                     Fail (E.Grammar_Too_Large, "elements");
                     Ok := False;
                     return;
                  end if;

                  Result :=
                    (Kind => Element_Reference, First => 0, Count => 0,
                     Inverted => False, Rule => Rule);
               end;

            when others =>
               if not Is_Name_Char (Peek) then
                  Fail (E.Grammar_Syntax_Error, [1 => Peek]);
                  Ok := False;
                  return;
               end if;

               declare
                  From : constant Natural := At_Byte;
                  Rule : Natural;
                  Good : Boolean;
               begin
                  while not Done and then Is_Name_Char (Peek) loop
                     At_Byte := At_Byte + 1;
                  end loop;

                  Named (Source (From .. At_Byte - 1), Rule, Good);
                  if not Good then
                     Fail (E.Grammar_Too_Large, "rules");
                     Ok := False;
                     return;
                  end if;

                  Result :=
                    (Kind => Element_Reference, First => 0, Count => 0,
                     Inverted => False, Rule => Rule);
               end;
         end case;
      end One_Item;

      --  Wrap one element in a rule that repeats it.
      --
      --  Star is `R ::= x R | ` -- the empty second alternative is what ends
      --  it -- and one-or-more is x followed by that. Optional is the same
      --  shape without the recursion.
      procedure Repeated
        (Inner   : Element;
         Star    : Boolean;
         Result  : out Element;
         Ok      : out Boolean)
      is
         Room : Pending;
         Used : Natural := 0;
         Rule : Natural;
         Good : Boolean;
      begin
         Result := Inner;

         Anonymous (Rule, Good);
         if not Good then
            Fail (E.Grammar_Too_Large, "rules");
            Ok := False;
            return;
         end if;

         Used := Used + 1;
         Room (Used) := Inner;

         if Star then
            Used := Used + 1;
            Room (Used) :=
              (Kind => Element_Reference, First => 0, Count => 0,
               Inverted => False, Rule => Rule);
            Is_Star (Rule) := True;
            Star_Offset (Rule) := At_Byte - Source'First;
         end if;

         --  The alternative that stops: empty, so an Alt marker with nothing
         --  after it before the rule ends.
         Used := Used + 1;
         Room (Used) := (Kind => Element_Alt, others => <>);

         Commit (Rule, Room, Used, Good);
         if not Good then
            Fail (E.Grammar_Too_Large, "elements");
            Ok := False;
            return;
         end if;

         Result :=
           (Kind => Element_Reference, First => 0, Count => 0,
            Inverted => False, Rule => Rule);
         Ok := True;
      end Repeated;

      --  A decimal count inside braces.
      procedure Read_Count (Value : out Natural; Present : out Boolean) is
      begin
         Value := 0;
         Present := False;

         while not Done and then Peek in '0' .. '9' loop
            if Value > 10_000 then
               Value := 10_001;
               return;
            end if;
            Value := Value * 10 + (Character'Pos (Peek) - Character'Pos ('0'));
            Present := True;
            At_Byte := At_Byte + 1;
         end loop;
      end Read_Count;

      procedure Alternatives
        (Room  : out Pending;
         Used  : out Natural;
         Depth : Natural;
         Ok    : out Boolean)
      is
         procedure Put (Item_Of : Element; Good : out Boolean) is
         begin
            if Used = Max_Pending then
               Fail (E.Grammar_Too_Large, "sequence");
               Good := False;
               return;
            end if;
            Used := Used + 1;
            Room (Used) := Item_Of;
            Good := True;
         end Put;
      begin
         Room := [others => (Kind => Element_End, others => <>)];
         Used := 0;
         Ok := True;

         loop
            --  One sequence.
            loop
               Skip_Blanks;
               exit when Done
                 or else Peek in '|' | ')' | Character'Val (0);

               --  A name followed by ::= belongs to the next rule, not to
               --  this sequence. Looking ahead for it is what lets rules be
               --  written one after another without a terminator.
               if Is_Name_Char (Peek) then
                  declare
                     Save : constant Natural := At_Byte;
                     Scan : Natural := At_Byte;
                  begin
                     while Scan <= Source'Last
                       and then Is_Name_Char (Source (Scan))
                     loop
                        Scan := Scan + 1;
                     end loop;
                     while Scan <= Source'Last
                       and then Source (Scan) in ' ' | Character'Val (9)
                                               | Character'Val (10)
                                               | Character'Val (13)
                     loop
                        Scan := Scan + 1;
                     end loop;

                     if Scan + 2 <= Source'Last
                       and then Source (Scan .. Scan + 2) = "::="
                     then
                        At_Byte := Save;
                        return;
                     end if;
                  end;
               end if;

               declare
                  Piece : Element;
                  Good  : Boolean;
               begin
                  One_Item (Piece, Depth, Good);
                  if not Good then
                     Ok := False;
                     return;
                  end if;

                  --  A postfix, if one follows immediately.
                  if not Done and then Peek in '?' | '*' | '+' then
                     declare
                        Mark    : constant Character := Peek;
                        Wrapped : Element;
                     begin
                        At_Byte := At_Byte + 1;

                        if Mark = '+' then
                           Put (Piece, Good);
                           if not Good then
                              Ok := False;
                              return;
                           end if;
                        end if;

                        Repeated (Piece, Mark /= '?', Wrapped, Good);
                        if not Good then
                           Ok := False;
                           return;
                        end if;
                        Piece := Wrapped;
                     end;

                  elsif not Done and then Peek = '{' then
                     declare
                        Least, Most : Natural := 0;
                        Has_Least, Has_Most : Boolean;
                        Bounded : Boolean := True;
                        Wrapped : Element;
                     begin
                        At_Byte := At_Byte + 1;
                        Read_Count (Least, Has_Least);
                        if not Has_Least or else Least > 1_000 then
                           Fail (E.Grammar_Syntax_Error, "repetition count");
                           Ok := False;
                           return;
                        end if;

                        Most := Least;
                        if not Done and then Peek = ',' then
                           At_Byte := At_Byte + 1;
                           Read_Count (Most, Has_Most);
                           if not Has_Most then
                              Bounded := False;
                           elsif Most < Least or else Most > 1_000 then
                              Fail (E.Grammar_Syntax_Error, "repetition count");
                              Ok := False;
                              return;
                           end if;
                        end if;

                        if Done or else Peek /= '}' then
                           Fail (E.Grammar_Syntax_Error, "repetition");
                           Ok := False;
                           return;
                        end if;
                        At_Byte := At_Byte + 1;

                        --  The required copies, then what makes up the rest.
                        for Each in 1 .. Least loop
                           Put (Piece, Good);
                           if not Good then
                              Ok := False;
                              return;
                           end if;
                        end loop;

                        if not Bounded then
                           Repeated (Piece, True, Wrapped, Good);
                           if not Good then
                              Ok := False;
                              return;
                           end if;
                           Piece := Wrapped;
                        else
                           --  Each further copy is optional, and each one
                           --  after the first only reachable through the
                           --  one before it, which is what makes a bound.
                           declare
                              Optional : Element := Piece;
                              Room2    : Pending;
                              Used2    : Natural;
                              Rule     : Natural;
                           begin
                              for Each in Least + 1 .. Most loop
                                 Anonymous (Rule, Good);
                                 if not Good then
                                    Fail (E.Grammar_Too_Large, "rules");
                                    Ok := False;
                                    return;
                                 end if;

                                 Used2 := 0;
                                 Used2 := Used2 + 1;
                                 Room2 (Used2) := Piece;
                                 if Each > Least + 1 then
                                    Used2 := Used2 + 1;
                                    Room2 (Used2) := Optional;
                                 end if;
                                 Used2 := Used2 + 1;
                                 Room2 (Used2) :=
                                   (Kind => Element_Alt, others => <>);

                                 Commit (Rule, Room2, Used2, Good);
                                 if not Good then
                                    Fail (E.Grammar_Too_Large, "elements");
                                    Ok := False;
                                    return;
                                 end if;

                                 Optional :=
                                   (Kind => Element_Reference, First => 0,
                                    Count => 0, Inverted => False,
                                    Rule => Rule);
                              end loop;

                              if Most > Least then
                                 Piece := Optional;
                              else
                                 --  Exactly Least copies, all emitted.
                                 Piece := (Kind => Element_End, others => <>);
                              end if;
                           end;
                        end if;

                        if Piece.Kind = Element_End then
                           goto Next_Piece;
                        end if;
                     end;
                  end if;

                  Put (Piece, Good);
                  if not Good then
                     Ok := False;
                     return;
                  end if;
               end;

               <<Next_Piece>>
            end loop;

            Skip_Blanks;
            exit when Done or else Peek /= '|';
            At_Byte := At_Byte + 1;

            declare
               Good : Boolean;
            begin
               Put ((Kind => Element_Alt, others => <>), Good);
               if not Good then
                  Ok := False;
                  return;
               end if;
            end;
         end loop;
      end Alternatives;

      Good : Boolean;
   begin
      Close (Item);
      Status := E.Success;

      loop
         Skip_Blanks;
         exit when Done;

         --  A rule: a name, ::=, and an alternative-list.
         declare
            From : constant Natural := At_Byte;
            Rule : Natural;
            Room : Pending;
            Used : Natural;
         begin
            if not Is_Name_Char (Peek) then
               Fail (E.Grammar_Syntax_Error, [1 => Peek]);
               Close (Item);
               return;
            end if;

            while not Done and then Is_Name_Char (Peek) loop
               At_Byte := At_Byte + 1;
            end loop;

            declare
               Name : constant String := Source (From .. At_Byte - 1);
            begin
               Skip_Blanks;
               if At_Byte + 2 > Source'Last
                 or else Source (At_Byte .. At_Byte + 2) /= "::="
               then
                  Fail (E.Grammar_Syntax_Error, "expected ::=");
                  Close (Item);
                  return;
               end if;
               At_Byte := At_Byte + 3;

               Named (Name, Rule, Good);
               if not Good then
                  Fail (E.Grammar_Too_Large, "rules");
                  Close (Item);
                  return;
               end if;

               if Item.Rules (Rule).Start /= 0 then
                  Fail (E.Grammar_Syntax_Error, Name);
                  Close (Item);
                  return;
               end if;

               Alternatives (Room, Used, 0, Good);
               if not Good then
                  Close (Item);
                  return;
               end if;

               Commit (Rule, Room, Used, Good);
               if not Good then
                  Fail (E.Grammar_Too_Large, "elements");
                  Close (Item);
                  return;
               end if;

               if Name = "root" then
                  Item.Root := Rule;
               end if;
            end;
         end;
      end loop;

      --  Every rule referred to has to be written somewhere.
      for Which in 1 .. Item.Rule_Used loop
         if Item.Rules (Which).Start = 0 then
            Status := E.Make (E.Grammar_Unknown_Rule);
            E.Add_Text
              (Status, "construct",
               Item.Names (Item.Rules (Which).Name_First
                           .. Item.Rules (Which).Name_Last),
               E.Param_Identifier);
            Close (Item);
            return;
         end if;
      end loop;

      if Item.Root = 0 then
         Status := E.Make (E.Grammar_Missing_Root);
         Close (Item);
         return;
      end if;

      --  Which rules can match empty text: an alternative of nothing but
      --  references to such rules, found by rounds until none changes. A
      --  star over one of them -- ("a"?)*, (ws)* with ws ::= [ ]* -- would
      --  enter itself again without reading a character, without end.
      declare
         Nullable : array (1 .. Max_Rules) of Boolean := [others => False];
         Changed  : Boolean := True;

         function Empty_Element (Index : Positive) return Boolean
         is (Item.Elements (Index).Kind = Element_Reference
             and then Nullable (Item.Elements (Index).Rule));
      begin
         while Changed loop
            Changed := False;
            for Which in 1 .. Item.Rule_Used loop
               if not Nullable (Which) then
                  declare
                     Index : Natural := Item.Rules (Which).Start;
                     All_Empty : Boolean := True;
                  begin
                     loop
                        case Item.Elements (Index).Kind is
                           when Element_Alt | Element_End =>
                              if All_Empty then
                                 Nullable (Which) := True;
                                 Changed := True;
                                 exit;
                              end if;
                              exit when Item.Elements (Index).Kind = Element_End;
                              All_Empty := True;
                           when Element_Char =>
                              All_Empty := False;
                           when Element_Reference =>
                              if not Empty_Element (Index) then
                                 All_Empty := False;
                              end if;
                        end case;
                        Index := Index + 1;
                     end loop;
                  end;
               end if;
            end loop;
         end loop;

         for Which in 1 .. Item.Rule_Used loop
            if Is_Star (Which)
              and then Empty_Element (Item.Rules (Which).Start)
            then
               Status := E.Make (E.Grammar_Syntax_Error);
               E.Add_Text
                 (Status, "construct",
                  "a repeat of what can match nothing", E.Param_Text);
               E.Add_Integer
                 (Status, "offset", Long_Long_Integer (Star_Offset (Which)),
                  E.Param_Offset);
               Close (Item);
               return;
            end if;
         end loop;
      end;

      Item.Ready := True;
   end Compile;

   ---------------------------------------------------------------------------
   --  Matching
   ---------------------------------------------------------------------------

   --  Whether a code point is in an element's set.
   function In_Set
     (Item  : Compiled;
      Which : Element;
      Value : Code_Point) return Boolean
   is
      Found : Boolean := False;
   begin
      for Index in Which.First .. Which.First + Which.Count - 1 loop
         if Value >= Item.Ranges (Index).Low
           and then Value <= Item.Ranges (Index).High
         then
            Found := True;
         end if;
      end loop;

      return Found /= Which.Inverted;
   end In_Set;

   --  Add a stack to a set, unless the same one is there already.
   procedure Remember
     (Into  : in out Matcher;
      Stack : Stack_Entry;
      Ok    : out Boolean)
   is
   begin
      for Index in 1 .. Into.Count loop
         if Into.Stacks (Index).Depth = Stack.Depth
           and then Into.Stacks (Index).Slots (1 .. Stack.Depth)
                    = Stack.Slots (1 .. Stack.Depth)
         then
            Ok := True;
            return;
         end if;
      end loop;

      if Into.Count = Max_Stacks then
         Ok := False;
         return;
      end if;

      Into.Count := Into.Count + 1;
      Into.Stacks (Into.Count) := Stack;
      Ok := True;
   end Remember;

   --  Expand a stack until its top is something a text can be matched
   --  against, forking wherever a rule offers alternatives.
   procedure Expand
     (Item  : Compiled;
      Stack : Stack_Entry;
      Into  : in out Matcher;
      Ok    : out Boolean);

   --  Enter a rule from a stack that has already been trimmed to where it
   --  should return to. One fork per alternative, and an alternative with no
   --  elements pushes nothing, which is how a rule that may match nothing
   --  reaches the return address straight away.
   procedure Enter
     (Item : Compiled;
      Base : Stack_Entry;
      Rule : Natural;
      Into : in out Matcher;
      Ok   : out Boolean)
   is
      At_Alt : Natural := Item.Rules (Rule).Start;
   begin
      Ok := True;

      loop
         declare
            Forked : Stack_Entry := Base;
         begin
            if Item.Elements (At_Alt).Kind in Element_Char
                                            | Element_Reference
            then
               if Forked.Depth = Max_Depth then
                  Ok := False;
                  return;
               end if;
               Forked.Depth := Forked.Depth + 1;
               Forked.Slots (Forked.Depth) := At_Alt;
            end if;

            Expand (Item, Forked, Into, Ok);
            if not Ok then
               return;
            end if;
         end;

         while Item.Elements (At_Alt).Kind in Element_Char
                                            | Element_Reference
         loop
            At_Alt := At_Alt + 1;
         end loop;

         exit when Item.Elements (At_Alt).Kind = Element_End;
         At_Alt := At_Alt + 1;
      end loop;
   end Enter;

   procedure Expand
     (Item  : Compiled;
      Stack : Stack_Entry;
      Into  : in out Matcher;
      Ok    : out Boolean)
   is
   begin
      Ok := True;

      if Stack.Depth = 0 then
         Remember (Into, Stack, Ok);
         return;
      end if;

      declare
         Top  : constant Natural := Stack.Slots (Stack.Depth);
         What : constant Element := Item.Elements (Top);
      begin
         case What.Kind is
            when Element_Char =>
               Remember (Into, Stack, Ok);

            when Element_Reference =>
               declare
                  Base : Stack_Entry := Stack;
                  Next : constant Natural := Top + 1;
               begin
                  --  What follows this reference in its own rule, if
                  --  anything does, is where to come back to.
                  Base.Depth := Base.Depth - 1;
                  if Item.Elements (Next).Kind in Element_Char
                                                | Element_Reference
                  then
                     if Base.Depth = Max_Depth then
                        Ok := False;
                        return;
                     end if;
                     Base.Depth := Base.Depth + 1;
                     Base.Slots (Base.Depth) := Next;
                  end if;

                  Enter (Item, Base, What.Rule, Into, Ok);
               end;

            when Element_Alt | Element_End =>
               --  A position never points at one of these: whatever advances
               --  a stack pops instead of stepping onto them.
               Ok := False;
         end case;
      end;
   end Expand;

   -----------
   -- Start --
   -----------

   procedure Start
     (Item   : Compiled;
      State  : out Matcher;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Empty : constant Stack_Entry := (Depth => 0, Slots => [others => 0]);
      Ok    : Boolean;
   begin
      State.Count := 0;
      State.Partial_Length := 0;
      Status := E.Success;

      if not Item.Ready then
         Status := E.Make (E.Grammar_Missing_Root);
         return;
      end if;

      --  From nowhere into the root, which is the same step the matcher
      --  takes at every reference: an alternative of the root is where a
      --  generation begins and an empty stack is where it may end.
      Enter (Item, Empty, Item.Root, State, Ok);

      if not Ok then
         Status := E.Make (E.Grammar_Too_Ambiguous);
         State.Count := 0;
      end if;
   end Start;

   --  Step every stack over one code point.
   procedure Step
     (Item  : Compiled;
      From  : Matcher;
      Value : Code_Point;
      Into  : in out Matcher;
      Ok    : out Boolean)
   is
   begin
      --  Only the count is reset. The stacks past it are never read, and
      --  clearing them wrote sixty-five kilobytes for every token of the
      --  vocabulary at every step -- which is most of what a grammar used
      --  to cost.
      Into.Count := 0;
      Ok := True;

      for Index in 1 .. From.Count loop
         declare
            Stack : constant Stack_Entry := From.Stacks (Index);
         begin
            if Stack.Depth > 0 then
               declare
                  Top  : constant Natural := Stack.Slots (Stack.Depth);
                  What : constant Element := Item.Elements (Top);
               begin
                  if What.Kind = Element_Char
                    and then In_Set (Item, What, Value)
                  then
                     declare
                        Moved : Stack_Entry := Stack;
                        Next  : constant Natural := Top + 1;
                     begin
                        Moved.Depth := Moved.Depth - 1;
                        if Item.Elements (Next).Kind in Element_Char
                                                      | Element_Reference
                        then
                           Moved.Depth := Moved.Depth + 1;
                           Moved.Slots (Moved.Depth) := Next;
                        end if;

                        Expand (Item, Moved, Into, Ok);
                        if not Ok then
                           return;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Step;

   -------------
   -- Accepts --
   -------------

   --  Whether any way the grammar is in the middle of could take this code
   --  point next.
   --
   --  Asked before anything is copied. A step offers every token of the
   --  vocabulary to the matcher and almost all of them are refused by their
   --  first character, so answering that question without building a
   --  successor state is the difference between a grammar costing more than
   --  the model and costing almost nothing.
   function Could_Begin
     (Item  : Compiled;
      State : Matcher;
      Value : Code_Point) return Boolean is
   begin
      for Index in 1 .. State.Count loop
         declare
            Stack : Stack_Entry renames State.Stacks (Index);
         begin
            if Stack.Depth > 0 then
               declare
                  What : constant Element :=
                    Item.Elements (Stack.Slots (Stack.Depth));
               begin
                  if What.Kind = Element_Char
                    and then In_Set (Item, What, Value)
                  then
                     return True;
                  end if;
               end;
            end if;
         end;
      end loop;

      return False;
   end Could_Begin;

   function Accepts_Whole
     (Item  : Compiled;
      State : Matcher;
      Text  : String) return Boolean;

   --  Whether a set holds any code point from Low to High: a range of them
   --  overlaps it, or -- inverted -- they are not all covered by it.
   function In_Set_Between
     (Item  : Compiled;
      Which : Element;
      Low   : Code_Point;
      High  : Code_Point) return Boolean
   is
      Next : Code_Point := Low;
      Moved : Boolean;
   begin
      if not Which.Inverted then
         for Index in Which.First .. Which.First + Which.Count - 1 loop
            if Item.Ranges (Index).Low <= High and then Item.Ranges (Index).High >= Low then
               return True;
            end if;
         end loop;
         return False;
      end if;
      --  Inverted: walk past the ranges that cover the start until one does
      --  not, or the end is passed.
      loop
         Moved := False;
         for Index in Which.First .. Which.First + Which.Count - 1 loop
            if Next >= Item.Ranges (Index).Low and then Next <= Item.Ranges (Index).High then
               if Item.Ranges (Index).High >= High then
                  return False;
               end if;
               Next := Item.Ranges (Index).High + 1;
               Moved := True;
            end if;
         end loop;
         exit when not Moved;
      end loop;
      return True;
   end In_Set_Between;

   --  Whether some code point a held start of a character can still become
   --  could begin here: a lead byte names a range of them, each byte after
   --  it narrows the range.
   function Could_Begin_Held
     (Item  : Compiled;
      State : Matcher;
      Held  : String) return Boolean
   is
      Lead  : constant Natural := Character'Pos (Held (Held'First));
      Total : constant Natural :=
        (if Lead in 16#C2# .. 16#DF# then 2 elsif Lead in 16#E0# .. 16#EF# then 3
         elsif Lead in 16#F0# .. 16#F4# then 4 else 0);
      Value : Natural;
      Left  : Natural;
      Low, High : Natural;
   begin
      if Total = 0 or else Held'Length >= Total then
         return False;
      end if;
      Value := Lead mod (2 ** (7 - Total));
      for Index in Held'First + 1 .. Held'Last loop
         Value := Value * 64 + Character'Pos (Held (Index)) mod 64;
      end loop;
      Left := Total - Held'Length;
      Low := Value * 64 ** Left;
      High := Low + 64 ** Left - 1;
      Low := Natural'Max (Low, (case Total is when 2 => 16#80#, when 3 => 16#800#, when others => 16#1_0000#));
      High := Natural'Min (High, 16#10_FFFF#);
      if Low > High then
         return False;
      end if;
      for Index in 1 .. State.Count loop
         declare
            Stack : Stack_Entry renames State.Stacks (Index);
         begin
            if Stack.Depth > 0 then
               declare
                  What : constant Element := Item.Elements (Stack.Slots (Stack.Depth));
               begin
                  if What.Kind = Element_Char
                    and then In_Set_Between (Item, What, Code_Point (Low), Code_Point (High))
                  then
                     return True;
                  end if;
               end;
            end if;
         end;
      end loop;
      return False;
   end Could_Begin_Held;

   function Accepts
     (Item  : Compiled;
      State : Matcher;
      Text  : String) return Boolean
   is
      Full : constant String := State.Partial (1 .. State.Partial_Length) & Text;
      Keep : constant Natural := Model_Runner.UTF8.Safe_Prefix_Length (Full);
   begin
      if not Item.Ready then
         return False;
      elsif Full = "" then
         return State.Count > 0;
      elsif Keep = Full'Length then
         return Accepts_Whole (Item, State, Full);
      end if;
      --  The characters it finishes, matched, and the start of one after
      --  them carried -- only where what it can still become is something
      --  the grammar could take next: a lead byte the grammar has no
      --  character for was taken, and then nothing could follow it.
      --  The characters before it refused cheaply first, before a matcher
      --  is copied for the start that follows them.
      if Keep > 0 and then not Accepts_Whole (Item, State, Full (Full'First .. Full'First + Keep - 1)) then
         return False;
      end if;
      declare
         Here   : Matcher := State;
         Status : Model_Runner.Errors.Error_Info;
      begin
         Here.Partial_Length := 0;
         if Keep > 0 then
            Advance (Item, Here, Full (Full'First .. Full'First + Keep - 1), Status);
            if E.Is_Error (Status) then
               return False;
            end if;
         end if;
         return Could_Begin_Held (Item, Here, Full (Full'First + Keep .. Full'Last));
      end;
   end Accepts;

   function Accepts_Whole
     (Item  : Compiled;
      State : Matcher;
      Text  : String) return Boolean
   is
      At_Byte : Natural := Text'First;
   begin

      --  The cheap answer first, and for most tokens it is the answer.
      if Text'Length > 0 then
         declare
            Value  : Natural;
            Length : Natural;
         begin
            Model_Runner.UTF8.Decode_First (Text, Value, Length);
            if Length = 0 then
               return False;
            end if;

            if not Could_Begin (Item, State, Code_Point (Value)) then
               return False;
            end if;

            --  One code point, and it was accepted: there is nothing left
            --  to simulate.
            if Length = Text'Length then
               return True;
            end if;
         end;
      end if;

      declare
         Here : Matcher;
         Next : Matcher;
         Ok   : Boolean;
      begin
         --  Only the stacks in use are copied. The rest of the array is not
         --  read, and copying it is the whole of what a long token used to
         --  cost.
         Here.Count := State.Count;
         Here.Stacks (1 .. State.Count) := State.Stacks (1 .. State.Count);

         while At_Byte <= Text'Last loop
            declare
               Value  : Natural;
               Length : Natural;
            begin
               Model_Runner.UTF8.Decode_First
                 (Text (At_Byte .. Text'Last), Value, Length);
               if Length = 0 then
                  return False;
               end if;

               Step (Item, Here, Code_Point (Value), Next, Ok);
               if not Ok or else Next.Count = 0 then
                  return False;
               end if;

               Here.Count := Next.Count;
               Here.Stacks (1 .. Next.Count) := Next.Stacks (1 .. Next.Count);
               At_Byte := At_Byte + Length;
            end;
         end loop;

         return Here.Count > 0;
      end;
   end Accepts_Whole;

   -------------
   -- Advance --
   -------------

   procedure Advance
     (Item   : Compiled;
      State  : in out Matcher;
      Text   : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      --  What was carried, and what it gives; a start of a character at
      --  its end is carried on.
      Full    : constant String := State.Partial (1 .. State.Partial_Length) & Text;
      Keep    : constant Natural := Model_Runner.UTF8.Safe_Prefix_Length (Full);
      Next    : Matcher;
      At_Byte : Natural := Full'First;
      Ok      : Boolean;
   begin
      Status := E.Success;

      if not Item.Ready then
         Status := E.Make (E.Grammar_Missing_Root);
         return;
      end if;

      State.Partial_Length := Full'Length - Keep;
      State.Partial (1 .. State.Partial_Length) := Full (Full'First + Keep .. Full'Last);

      while At_Byte <= Full'First + Keep - 1 loop
         declare
            Value  : Natural;
            Length : Natural;
         begin
            Model_Runner.UTF8.Decode_First
              (Full (At_Byte .. Full'First + Keep - 1), Value, Length);
            if Length = 0 then
               Status := E.Make (E.Grammar_Syntax_Error);
               return;
            end if;

            Step (Item, State, Code_Point (Value), Next, Ok);
            if not Ok then
               Status := E.Make (E.Grammar_Too_Ambiguous);
               return;
            end if;

            if Next.Count = 0 then
               Status := E.Make (E.Grammar_Syntax_Error);
               return;
            end if;

            State.Count := Next.Count;
            State.Stacks (1 .. Next.Count) :=
              Next.Stacks (1 .. Next.Count);
            At_Byte := At_Byte + Length;
         end;
      end loop;
   end Advance;

   -----------------
   -- Is_Complete --
   -----------------

   function Is_Complete
     (Item  : Compiled;
      State : Matcher) return Boolean
   is
      pragma Unreferenced (Item);
   begin
      if State.Partial_Length > 0 then
         return False;
      end if;
      for Index in 1 .. State.Count loop
         if State.Stacks (Index).Depth = 0 then
            return True;
         end if;
      end loop;

      return False;
   end Is_Complete;

   ---------------
   -- Excluding --
   ---------------

   function Excluding
     (Rule    : String;
      Literal : String;
      Ending  : Boolean := True) return String
   is
      LF : constant String := [1 => Character'Val (10)];

      --  The literals' code points, one row a literal; Literal holds them
      --  parted by line breaks.
      Most_Literals : constant := 8;
      Most_Points   : constant := 64;
      type Row is array (1 .. Most_Points) of Natural;
      Points  : array (1 .. Most_Literals) of Row := [others => [others => 0]];
      Lengths : array (1 .. Most_Literals) of Natural := [others => 0];
      Held    : Natural := 0;

      --  One code point as this grammar escapes it.
      function Escaped (Value : Natural) return String is
         Hex   : constant String := "0123456789ABCDEF";
         Out_S : String (1 .. 10) := "\U00000000";
         Rest  : Natural := Value;
      begin
         for Index in reverse 3 .. 10 loop
            Out_S (Index) := Hex (Hex'First + Rest mod 16);
            Rest := Rest / 16;
         end loop;
         return Out_S;
      end Escaped;

      --  A literal's first Count code points, quoted.
      function Prefix (Which, Count : Natural) return String is
         Result : String (1 .. 2 + 10 * Count);
         Used   : Natural := 1;
      begin
         Result (1) := '"';
         for Index in 1 .. Count loop
            Result (Used + 1 .. Used + 10) := Escaped (Points (Which) (Index));
            Used := Used + 10;
         end loop;
         Result (Used + 1) := '"';
         return Result (1 .. Used + 1);
      end Prefix;

      --  Whether literal A's first Count points are literal B's.
      function Same (A, B, Count : Natural) return Boolean is
      begin
         if Lengths (B) < Count then
            return False;
         end if;
         for Index in 1 .. Count loop
            if Points (A) (Index) /= Points (B) (Index) then
               return False;
            end if;
         end loop;
         return True;
      end Same;

      --  Whether literal Which's first Count points were met as an earlier
      --  literal's, so each beginning is written once.
      function Seen (Which, Count : Natural) return Boolean is
      begin
         for Earlier in 1 .. Which - 1 loop
            if Count < Lengths (Earlier) and then Same (Which, Earlier, Count)
            then
               return True;
            end if;
         end loop;
         return False;
      end Seen;

      --  What may not follow literal Which's first Count points: whatever
      --  continues any literal that begins so, and -- after a beginning --
      --  whatever begins one again, so that a fresh beginning is never
      --  taken as text.
      function Stops (Which, Count : Natural) return String is
         Result : String (1 .. 10 * 2 * Most_Literals);
         Used   : Natural := 0;

         procedure Add (Value : Natural) is
            Code : constant String := Escaped (Value);
         begin
            for At_Code in 0 .. Used / 10 - 1 loop
               if Result (At_Code * 10 + 1 .. At_Code * 10 + 10) = Code then
                  return;
               end if;
            end loop;
            Result (Used + 1 .. Used + 10) := Code;
            Used := Used + 10;
         end Add;
      begin
         for Other in 1 .. Held loop
            if Count < Lengths (Other) and then Same (Which, Other, Count) then
               Add (Points (Other) (Count + 1));
            end if;
            if Count > 0 then
               Add (Points (Other) (1));
            end if;
         end loop;
         return "[^" & Result (1 .. Used) & "]";
      end Stops;

      At_Byte : Natural := Literal'First;
   begin
      --  The literals, parted.
      while At_Byte <= Literal'Last loop
         if Held = 0 or else Literal (At_Byte) = Character'Val (10) then
            if Held = Most_Literals then
               exit;
            end if;
            Held := Held + 1;
            if Literal (At_Byte) = Character'Val (10) then
               At_Byte := At_Byte + 1;
               goto Next_Byte;
            end if;
         end if;
         declare
            Value, Length : Natural;
         begin
            Model_Runner.UTF8.Decode_First
              (Literal (At_Byte .. Literal'Last), Value, Length);
            if Lengths (Held) < Most_Points then
               Lengths (Held) := Lengths (Held) + 1;
               Points (Held) (Lengths (Held)) :=
                 (if Length = 0 then Character'Pos (Literal (At_Byte))
                  else Value);
            end if;
            At_Byte := At_Byte + Natural'Max (Length, 1);
         end;
         <<Next_Byte>>
      end loop;

      if Held = 0 or else Lengths (1) = 0 then
         return Rule & " ::= [^\x00]*" & LF;
      end if;

      --  Where no literal holds a literal's first character past its own
      --  front -- every opener and close this program writes -- a text is
      --  runs of other characters and of beginnings: a beginning followed
      --  by a first character is a beginning cut short, the next one
      --  starting there, and a run of them ends on a character that
      --  neither continues the last nor begins one. Written as one
      --  beginning and what may not follow it, a "<" before "<" -- C++'s
      --  <<, a shell's heredoc -- was refused, as "[[" before Mistral's
      --  opener was.
      declare
         --  Whether a code point is some literal's first.
         function Is_First (Value : Natural) return Boolean is
         begin
            for Other in 1 .. Held loop
               if Lengths (Other) > 0 and then Points (Other) (1) = Value then
                  return True;
               end if;
            end loop;
            return False;
         end Is_First;

         Clean : Boolean := True;
         Beginnings_Text : String (1 .. 32 * 1024);
         Beginnings_Used : Natural := 0;
         Exits_Text : String (1 .. 64 * 1024);
         Exits_Used : Natural := 0;
      begin
         for Which in 1 .. Held loop
            for Index in 2 .. Lengths (Which) loop
               if Is_First (Points (Which) (Index)) then
                  Clean := False;
               end if;
            end loop;
         end loop;

         if Clean then
            for Which in 1 .. Held loop
               for Count in 1 .. Lengths (Which) - 1 loop
                  if not Seen (Which, Count) then
                     declare
                        Begun : constant String :=
                          (if Beginnings_Used = 0 then "" else " | ")
                          & Prefix (Which, Count);
                        Left  : constant String :=
                          (if Exits_Used = 0 then "" else " | ")
                          & Prefix (Which, Count) & " " & Stops (Which, Count);
                     begin
                        Beginnings_Text
                          (Beginnings_Used + 1
                           .. Beginnings_Used + Begun'Length) := Begun;
                        Beginnings_Used := Beginnings_Used + Begun'Length;
                        Exits_Text (Exits_Used + 1 .. Exits_Used + Left'Length)
                          := Left;
                        Exits_Used := Exits_Used + Left'Length;
                     end;
                  end if;
               end loop;
            end loop;

            --  Every literal one character long: none of them is written.
            if Beginnings_Used = 0 then
               return Rule & " ::= " & Stops (1, 0) & "*" & LF;
            end if;

            return Rule & " ::= ( " & Stops (1, 0) & " | " & Rule & "_run )*"
              & (if Ending then " " & Rule & "_end?" else "") & LF
              & Rule & "_run ::= " & Rule & "_begun* ( "
              & Exits_Text (1 .. Exits_Used) & " )" & LF
              & Rule & "_begun ::= " & Beginnings_Text (1 .. Beginnings_Used)
              & LF
              & (if Ending
                 then Rule & "_end ::= " & Rule & "_begun+" & LF
                 else "");
         end if;
      end;

      --  Otherwise no first character at all: a literal holding one past
      --  its front can be begun again inside itself, which runs of
      --  beginnings do not follow. Narrower than the literals say, never
      --  wider -- every literal this program writes is the other kind.
      return Rule & " ::= " & Stops (1, 0) & "*" & LF;
   end Excluding;

end Model_Runner.Grammar;
