separate (Model_Runner.Templates)
procedure Compile
  (Item   : in out Compiled;
   Source : String;
   Bounds : Model_Runner.Limits.Model_Limits :=
     Model_Runner.Limits.Default_Model_Limits;
   Status : out E.Error_Info)
is
   Frames : Frame_Array := [others => <>];
   Depth  : Natural := 0;

   --  How deep the brackets are around what is being read. A template is
   --  untrusted text and a group is read by recursion, so the same bound
   --  the blocks are held to holds the brackets: reading stops rather
   --  than the stack running out.
   Group_Depth : Natural := 0;

   --  Jump instructions that must be patched to the end of the enclosing
   --  if. Chained through the Target field so that no extra storage grows
   --  with the template.
   Exit_Chain : array (1 .. Max_Depth) of Natural := [others => 0];

   --  A statement's text as a refusal names it: after its keyword,
   --  trimmed, and cut to a line's worth so a long condition does not
   --  bury the message.
   function Shown (Text : String; Keyword : String) return String is
      Whole : constant String := Model_Runner.Text.Trim (Text);
      Most  : constant := 80;
   begin
      return Keyword
        & (if Whole'Length <= Most then Whole
           else Whole (Whole'First .. Whole'First + Most - 1) & "...");
   end Shown;

   procedure Fail (Code : E.Error_Code; Detail : String := "") is
   begin
      Status := E.Make (Code);
      if Detail /= "" then
         E.Add_Text (Status, "construct", Detail, E.Param_Identifier);
      end if;
      Close (Item);
   end Fail;

   --  Append an instruction, reporting the instruction-count bound.
   --  Put an operand aside and return where it went. The table starts
   --  small and doubles, so a template with one output pays for one.
   procedure Keep (Value : Operand; Position : out Natural) is
   begin
      Position := 0;

      --  Kept before the instruction that names it is emitted, so this
      --  is where the cap is met first. Emit refuses too, and the caller
      --  stops on either.
      if Item.Operand_Used >= Max_Instructions then
         Fail (E.Template_Too_Large, "instructions");
         return;
      end if;

      if Item.Operands = null then
         Item.Operands := new Operand_Array (1 .. 8);
      elsif Item.Operand_Used = Item.Operands.all'Length then
         declare
            Wider : constant Operand_Array_Access :=
              new Operand_Array
                (1 .. Natural'Min (Item.Operands.all'Length * 2,
                                   Max_Instructions));
            Older : Operand_Array_Access := Item.Operands;
         begin
            --  It cannot fail to grow: every operand belongs to an
            --  instruction, and those are capped at Max_Instructions.
            Wider.all (1 .. Item.Operand_Used) :=
              Older.all (1 .. Item.Operand_Used);
            Item.Operands := Wider;
            Free_Operands (Older);
         end;
      end if;

      Item.Operand_Used := Item.Operand_Used + 1;
      Item.Operands.all (Item.Operand_Used) := Value;
      Position := Item.Operand_Used;
   end Keep;

   --  The same for a condition.
   procedure Keep (Value : Condition; Position : out Natural) is
   begin
      Position := 0;

      --  Kept before the instruction that names it is emitted, so this
      --  is where the cap is met first. Emit refuses too, and the caller
      --  stops on either.
      if Item.Condition_Used >= Max_Instructions then
         Fail (E.Template_Too_Large, "instructions");
         return;
      end if;

      if Item.Conditions = null then
         Item.Conditions := new Condition_Array (1 .. 8);
      elsif Item.Condition_Used = Item.Conditions.all'Length then
         declare
            Wider : constant Condition_Array_Access :=
              new Condition_Array
                (1 .. Natural'Min (Item.Conditions.all'Length * 2,
                                   Max_Instructions));
            Older : Condition_Array_Access := Item.Conditions;
         begin
            Wider.all (1 .. Item.Condition_Used) :=
              Older.all (1 .. Item.Condition_Used);
            Item.Conditions := Wider;
            Free_Conditions (Older);
         end;
      end if;

      Item.Condition_Used := Item.Condition_Used + 1;
      Item.Conditions.all (Item.Condition_Used) := Value;
      Position := Item.Condition_Used;
   end Keep;

   procedure Emit (Value : Instruction; Position : out Natural) is
   begin
      Position := 0;
      if Item.Program_Used >= Max_Instructions then
         Fail (E.Template_Too_Large, "instructions");
         return;
      end if;
      Item.Program_Used := Item.Program_Used + 1;
      Item.Program.all (Item.Program_Used) := Value;
      Position := Item.Program_Used;
   end Emit;

   --  Skip spaces in a tag body.
   function Skip_Spaces (Text : String; From : Natural) return Natural is
      Index : Natural := From;
   begin
      while Index <= Text'Last
        and then (Text (Index) = ' ' or else Text (Index) = ASCII.HT
                  or else Text (Index) = ASCII.LF
                  or else Text (Index) = ASCII.CR)
      loop
         Index := Index + 1;
      end loop;
      return Index;
   end Skip_Spaces;

   --  Read one identifier-like word.
   procedure Read_Word
     (Text  : String;
      From  : in out Natural;
      First : out Natural;
      Last  : out Natural)
   is
      Start : constant Natural := Skip_Spaces (Text, From);
      Index : Natural := Start;
   begin
      while Index <= Text'Last
        and then (Text (Index) in 'a' .. 'z'
                  or else Text (Index) in 'A' .. 'Z'
                  or else Text (Index) in '0' .. '9'
                  or else Text (Index) = '_'
                  or else Text (Index) = '.')
      loop
         Index := Index + 1;
      end loop;
      First := Start;
      Last := Index - 1;
      From := Index;
   end Read_Word;

   --  Copy a string literal's decoded bytes into the compiled source pool
   --  and return the slice.
   procedure Store_Literal
     (Content : String;
      Offset  : out Natural;
      Length  : out Natural;
      Ok      : out Boolean) is
   begin
      Offset := Item.Source_Used;
      Length := Content'Length;
      Ok := Item.Source_Used + Content'Length <= Item.Source.all'Length;
      if Ok and then Content'Length > 0 then
         Item.Source.all
           (Item.Source_Used + 1 .. Item.Source_Used + Content'Length) :=
           Content;
         Item.Source_Used := Item.Source_Used + Content'Length;
      end if;
   end Store_Literal;

   --  Whether a word is a name a template could have assigned. A dotted
   --  word is a field of something, and this engine has no objects with
   --  fields beyond the ones it names outright.
   function Is_Plain_Name (Word : String) return Boolean is
   begin
      if Word'Length = 0 or else Word (Word'First) in '0' .. '9' then
         return False;
      end if;
      for Letter of Word loop
         if Letter not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' then
            return False;
         end if;
      end loop;
      return True;
   end Is_Plain_Name;

   --  The names a template has made into namespaces, by slot.
   --
   --  A namespace is a holder with named fields, and the reason templates
   --  use one is that a name assigned inside a loop does not outlive the
   --  loop while a field of a namespace does. That is how the render
   --  treats them too, and the dot is what tells the two apart there, so
   --  a namespace needs no machinery of its own: ns.field is a name like
   --  any other, spelled with a dot. What the set below is for is
   --  telling that name apart from message.role, which is also spelled
   --  with a dot and is not a name at all.
   Namespaces : array (1 .. Max_Variables) of Boolean := [others => False];

   --  Whether Word is HEAD.FIELD for a head some namespace() named.
   function Is_Namespace_Field (Word : String) return Boolean is
   begin
      for Index in Word'Range loop
         if Word (Index) = '.' then
            if Index = Word'First or else Index = Word'Last then
               return False;
            end if;

            declare
               Head : constant String := Word (Word'First .. Index - 1);
            begin
               for Slot in 1 .. Item.Name_Used loop
                  declare
                     Held : Variable_Name renames Item.Names (Slot);
                  begin
                     if Namespaces (Slot)
                       and then Item.Source.all
                                  (Held.Offset + 1
                                   .. Held.Offset + Held.Length) = Head
                     then
                        return True;
                     end if;
                  end;
               end loop;
            end;
            return False;
         end if;
      end loop;
      return False;
   end Is_Namespace_Field;

   --  Whether the template has given Name a value of its own so far:
   --  a name in the table got there by being assigned or read as one.
   function Is_Assigned (Name : String) return Boolean is
   begin
      for Index in 1 .. Item.Name_Used loop
         declare
            Held : Variable_Name renames Item.Names (Index);
         begin
            if Item.Source.all (Held.Offset + 1 .. Held.Offset + Held.Length)
              = Name
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Is_Assigned;

   --  Position of a name in the variable table, adding it when it is new.
   --  Zero when the table is full, which makes the term unsupported rather
   --  than the template unusable.
   function Slot_Of (Name : String) return Natural is
      Offset, Length : Natural;
      Stored         : Boolean;
   begin
      for Index in 1 .. Item.Name_Used loop
         declare
            Held : Variable_Name renames Item.Names (Index);
         begin
            if Item.Source.all (Held.Offset + 1 .. Held.Offset + Held.Length)
              = Name
            then
               return Index;
            end if;
         end;
      end loop;

      if Item.Name_Used >= Max_Variables then
         return 0;
      end if;

      Store_Literal (Name, Offset, Length, Stored);
      if not Stored then
         return 0;
      end if;

      Item.Name_Used := Item.Name_Used + 1;
      Item.Names (Item.Name_Used) := (Offset => Offset, Length => Length);

      --  The name the tools arrive under, recorded where it is first
      --  met. A template that never writes the word spends no slot on it
      --  and is told apart from one that does by this being zero, which
      --  is what a caller with tools and no template for them asks.
      if Name = "tools" then
         Item.Tools_Slot := Item.Name_Used;
      end if;

      --  And the name one call goes by, recorded the same way and for
      --  the same reason: a template that walks no calls spends no slot
      --  on the name of what it would have bound.
      if Name = "tool_call" then
         Item.Call_Slot := Item.Name_Used;
      end if;

      return Item.Name_Used;
   end Slot_Of;

   --  Which macro a name is, or zero when the template defined none by
   --  that name so far. Defined before it is called, as the language
   --  reads a template top to bottom.
   function Macro_Named (Name : String) return Natural is
   begin
      for Index in 1 .. Item.Macro_Used loop
         declare
            Held : Variable_Name renames Item.Macros (Index).Name;
         begin
            if Item.Source.all (Held.Offset + 1 .. Held.Offset + Held.Length)
              = Name
            then
               return Index;
            end if;
         end;
      end loop;
      return 0;
   end Macro_Named;

   --  A term the engine cannot evaluate, named so that the render which
   --  reaches it can say what it was.
   function Refused
     (Name : String;
      Why  : E.Error_Code := E.Template_Unsupported_Construct) return Term
   is
      Result : Term := (Kind => Term_Unsupported, Why => Why, others => <>);
      Stored : Boolean;
   begin
      Store_Literal (Name, Result.Offset, Result.Length, Stored);
      if not Stored then
         Result.Length := 0;
      end if;
      return Result;
   end Refused;

   --  Declared here because a term may hold one: the index of an indexed
   --  message is an expression, and an expression is an operand.
   --  Where the bracket opened at First is closed, or zero when nothing
   --  closes it. Quotes are honoured, because a bracket inside a literal
   --  closes nothing.
   function Closes_At (Text : String; First : Natural) return Natural is
      Depth_Here : Natural := 0;
      Quote      : Character := ' ';
   begin
      for Index in First .. Text'Last loop
         if Quote /= ' ' then
            if Text (Index) = Quote then
               Quote := ' ';
            end if;
         elsif Text (Index) = ''' or else Text (Index) = '"' then
            Quote := Text (Index);
         elsif Text (Index) = '(' then
            Depth_Here := Depth_Here + 1;
         elsif Text (Index) = ')' then
            Depth_Here := Depth_Here - 1;
            if Depth_Here = 0 then
               return Index;
            end if;
         end if;
      end loop;
      return 0;
   end Closes_At;

   --  Where Word stands in Held as a word of its own -- spaces or the
   --  ends of the text on either side of it -- outside quotes and outside
   --  brackets, at or after After. Zero when it does not stand there at
   --  all. What it is for is telling the parts of a one-line choice
   --  apart: the if and the else of "A if C else B" are the template's,
   --  and the ones inside a quoted marker or inside brackets are not.
   function Word_At
     (Held : String; Word : String; After : Natural := 0) return Natural
   is
      Level : Natural := 0;
      Quote : Character := ' ';
      From  : constant Natural :=
        (if After = 0 then Held'First else After);
   begin
      for Index in From .. Held'Last - Word'Length + 1 loop
         if Quote /= ' ' then
            if Held (Index) = Quote then
               Quote := ' ';
            end if;
         elsif Held (Index) = ''' or else Held (Index) = '"' then
            Quote := Held (Index);
         elsif Held (Index) = '(' or else Held (Index) = '[' then
            Level := Level + 1;
         elsif Held (Index) = ')' or else Held (Index) = ']' then
            if Level > 0 then
               Level := Level - 1;
            end if;
         elsif Level = 0
           and then Held (Index .. Index + Word'Length - 1) = Word
           and then (Index = Held'First
                     or else Held (Index - 1) = ' ')
           and then (Index + Word'Length > Held'Last
                     or else Held (Index + Word'Length) = ' ')
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Word_At;

   procedure Read_Operand
     (Text   : String;
      From   : in out Natural;
      Result : out Operand;
      Ok     : out Boolean);

   procedure Read_Condition
     (Text   : String;
      Result : out Condition;
      Ok     : out Boolean);

   --  Where a word stands on its own at the top level of Text: outside
   --  quotes and brackets, with blanks on both sides. Zero when it does
   --  not. What tells "(A if C else B)" from a group holding a sum.
   function Top_Level_Word (Text : String; Word : String) return Natural is
      Depth : Natural := 0;
      Quote : Character := ' ';
      Index : Natural := Text'First;
   begin
      while Index <= Text'Last loop
         declare
            C : constant Character := Text (Index);
         begin
            if Quote /= ' ' then
               if C = Quote then
                  Quote := ' ';
               end if;
            elsif C in ''' | '"' then
               Quote := C;
            elsif C in '(' | '[' | '{' then
               Depth := Depth + 1;
            elsif C in ')' | ']' | '}' then
               Depth := (if Depth > 0 then Depth - 1 else 0);
            elsif Depth = 0 and then C = ' '
              and then Index + Word'Length + 1 <= Text'Last
              and then Text (Index + 1 .. Index + Word'Length) = Word
              and then Text (Index + Word'Length + 1) = ' '
            then
               return Index + 1;
            end if;
         end;
         Index := Index + 1;
      end loop;
      return 0;
   end Top_Level_Word;

   --  A bracketed group that is not a sum: a choice written inside an
   --  expression, "(A if C else B)", or a comparison or test written
   --  as a value, "(a == b)", "(x is defined)". Ok is False when it is
   --  neither.
   procedure Read_Value_Group
     (Held   : String;
      Result : out Term;
      Ok     : out Boolean)
   is separate;

   --  The whole of Text as one operand: a sum or a term, or failing
   --  that a choice, a comparison or an "or" written as a value --
   --  what an argument to a macro or a filter may be.
   procedure Read_Expression
     (Text   : String;
      Result : out Operand;
      Ok     : out Boolean)
   is
      Scan  : Natural := Text'First;
      Group : Term;
   begin
      Read_Operand (Text, Scan, Result, Ok);
      if Ok and then Skip_Spaces (Text, Scan) > Text'Last then
         return;
      end if;
      Read_Value_Group (Model_Runner.Text.Trim (Text), Group, Ok);
      if Ok then
         Result := (Terms => [1 => Group, others => <>], Count => 1);
      end if;
   end Read_Expression;

   --  Where the next top-level comma is in Text from From, or past
   --  the end: outside quotes and brackets.
   function Comma_After (Text : String; From : Natural) return Natural is
      Depth : Natural := 0;
      Quote : Character := ' ';
   begin
      for Index in From .. Text'Last loop
         declare
            C : constant Character := Text (Index);
         begin
            if Quote /= ' ' then
               if C = Quote then
                  Quote := ' ';
               end if;
            elsif C in ''' | '"' then
               Quote := C;
            elsif C in '(' | '[' | '{' then
               Depth := Depth + 1;
            elsif C in ')' | ']' | '}' then
               Depth := (if Depth > 0 then Depth - 1 else 0);
            elsif C = ',' and then Depth = 0 then
               return Index;
            end if;
         end;
      end loop;
      return Text'Last + 1;
   end Comma_After;

   --  The methods a template may write after a piece of text, and the
   --  spelling each is recognised by. Longest last, because the shorter
   --  of two that end alike would match the longer one first.
   type Method_Name is record
      Text : access constant String;
      Kind : Method_Kind;
   end record;

   Strip_Name  : aliased constant String := ".strip";
   LStrip_Name : aliased constant String := ".lstrip";
   RStrip_Name : aliased constant String := ".rstrip";
   Split_Name  : aliased constant String := ".split";
   Starts_Name : aliased constant String := ".startswith";
   Ends_Name   : aliased constant String := ".endswith";
   Replace_Name : aliased constant String := ".replace";
   Items_Name  : aliased constant String := ".items";

   Keys_Name   : aliased constant String := ".keys";
   Values_Name : aliased constant String := ".values";
   Get_Name    : aliased constant String := ".get";
   Upper_Name  : aliased constant String := ".upper";
   Lower_Name  : aliased constant String := ".lower";
   Title_Name  : aliased constant String := ".title";
   Capital_Name : aliased constant String := ".capitalize";
   Format_Name : aliased constant String := ".format";

   Method_Names : constant array (1 .. 16) of Method_Name :=
     [(Strip_Name'Access, Method_Strip),
      (LStrip_Name'Access, Method_Left_Strip),
      (RStrip_Name'Access, Method_Right_Strip),
      (Split_Name'Access, Method_Split_First),
      (Starts_Name'Access, Method_Starts_With),
      (Ends_Name'Access, Method_Ends_With),
      (Replace_Name'Access, Method_Replace),
      (Items_Name'Access, Method_Items),
      (Keys_Name'Access, Method_Keys),
      (Values_Name'Access, Method_Values),
      (Get_Name'Access, Method_Get),
      (Upper_Name'Access, Method_Upper),
      (Lower_Name'Access, Method_Lower),
      (Title_Name'Access, Method_Title),
      (Capital_Name'Access, Method_Capitalize),
      (Format_Name'Access, Method_Format)];

   procedure Read_Bare_Term
     (Text   : String;
      From   : in out Natural;
      Result : out Term;
      Ok     : out Boolean);

   --  Read what follows a method's name -- its one argument, and for a
   --  cut the side that is kept -- and add it to a term's chain.
   procedure Add_Method
     (Text   : String;
      Doing  : Method_Kind;
      From   : in out Natural;
      Result : in out Term;
      Ok     : out Boolean)
   is separate;

   --  Read one term without its filter. Terms are the only values the
   --  engine knows; anything else reads as unsupported.
   --  Whether an operand is a number by construction: any join but plus
   --  makes it one, and so does a plus between numbers. The same rule
   --  Render's Is_Sum reads at render time, read here for a group.
   function Sums (Value : Operand) return Boolean is
   begin
      if Value.Count <= 1 then
         return Value.Count = 1 and then Value.Terms (1).Numeric;
      end if;
      for Index in 2 .. Value.Count loop
         if Value.Terms (Index).Join = Join_Concat then
            return False;
         end if;
      end loop;
      for Index in 2 .. Value.Count loop
         if Value.Terms (Index).Join /= Join_Plus then
            return True;
         end if;
      end loop;
      return (for all Index in 1 .. Value.Count =>
                Value.Terms (Index).Numeric);
   end Sums;

   --  How many elements a list or mapping written out may have, and
   --  the room they are read into before they are kept.
   Max_Literal_Elements : constant := 64;
   type Operand_List is array (1 .. Max_Literal_Elements) of Operand;

   procedure Read_Bare_Term
     (Text   : String;
      From   : in out Natural;
      Result : out Term;
      Ok     : out Boolean)
   is separate;

   --  Read a term and whatever filter follows it.
   --  What may follow a term once it has been read: methods, positions
   --  and members in any order, then filters. A bracketed group takes
   --  the same tail, which is how "(x | list)[0].name" is read.
   procedure Read_Tail
     (Text   : String;
      From   : in out Natural;
      Result : in out Term) is separate;

   procedure Read_Term
     (Text   : String;
      From   : in out Natural;
      Result : out Term;
      Ok     : out Boolean) is
   begin
      Read_Bare_Term (Text, From, Result, Ok);
      if not Ok then
         return;
      end if;
      Read_Tail (Text, From, Result);
   end Read_Term;

   --  Read a '+'-joined run of terms.
   procedure Read_Operand
     (Text   : String;
      From   : in out Natural;
      Result : out Operand;
      Ok     : out Boolean)
   is separate;

   --  Read whatever follows a clause's left operand: a comparison, an
   --  'is' test, an 'in' test, or nothing at all.
   --  Whether the next word at From is Word, without consuming anything.
   function Follows_With
     (Text : String; From : Natural; Word : String) return Boolean
   is
      Scan        : Natural := From;
      First, Last : Natural;
   begin
      Read_Word (Text, Scan, First, Last);
      return Last >= First and then Text (First .. Last) = Word;
   end Follows_With;

   procedure Read_Test
     (Text    : String;
      From    : in out Natural;
      Current : in out Clause;
      Ok      : out Boolean)
   is separate;

   --  Read a condition: an or-list of and-lists of clauses. Recurses on
   --  parentheses, bounded by Level.
   procedure Read_Condition
     (Text   : String;
      From   : in out Natural;
      Level  : Natural;
      Result : out Condition;
      Ok     : out Boolean)
   is
   begin
      Result := (others => <>);
      Ok := False;

      Result.Group_Used := 1;
      Result.Groups (1) := (First => 1, Count => 0);

      loop
         declare
            Current : Clause;
            Taken   : Boolean;
            Probe   : Natural := Skip_Spaces (Text, From);
         begin
            --  Optional negation.
            if Probe + 2 <= Text'Last
              and then Text (Probe .. Probe + 2) = "not"
              and then (Probe + 3 > Text'Last
                        or else Text (Probe + 3) = ' '
                        or else Text (Probe + 3) = '(')
            then
               Current.Negated := True;
               From := Probe + 3;
            else
               From := Probe;
            end if;

            Probe := Skip_Spaces (Text, From);
            --  A bracket opens a group of clauses, unless what follows
            --  its closing bracket goes on reading a value -- a method,
            --  a filter, an index, as (content | default('')).strip()
            --  -- or it holds a tuple: then it is an operand, and read
            --  as one with the comparison it stands in.
            if Probe <= Text'Last and then Text (Probe) = '('
              and then not Is_Tuple_At (Text, Probe)
              and then (declare
                          Shut : constant Natural :=
                            Closes_At (Text, Probe);
                          Next : constant Natural :=
                            (if Shut = 0 then Text'Last + 1
                             else Skip_Spaces (Text, Shut + 1));
                        begin
                          Shut = 0
                          or else Next > Text'Last
                          or else Text (Next) not in '.' | '|' | '[')
            then
               if Level >= Max_Depth then
                  return;
               end if;

               declare
                  Inner : Condition;
                  Good  : Boolean;
                  Held  : Natural;
               begin
                  From := Probe + 1;
                  Read_Condition (Text, From, Level + 1, Inner, Good);
                  if not Good then
                     return;
                  end if;

                  Probe := Skip_Spaces (Text, From);
                  if Probe > Text'Last or else Text (Probe) /= ')' then
                     return;
                  end if;
                  From := Probe + 1;

                  Keep (Inner, Held);
                  if Held = 0 then
                     return;
                  end if;

                  --  A group compared with something -- "(a == b) !=
                  --  (c == d)" -- is a value on the left of a test
                  --  rather than a condition of its own; and a group
                  --  holding one bare operand, "(i | string) is
                  --  string", is that operand.
                  if Inner.Clause_Used = 1
                    and then Inner.Clauses (1).Operator = Compare_None
                    and then not Inner.Clauses (1).Negated
                    and then Inner.Clauses (1).Sub_At = 0
                  then
                     Current.Left := Inner.Clauses (1).Left;
                     Read_Test (Text, From, Current, Taken);
                     if not Taken then
                        return;
                     end if;
                  else
                     Current.Left :=
                       (Terms => [1 => (Kind => Term_Condition,
                                        Offset => Held, others => <>),
                                  others => <>],
                        Count => 1);
                     Read_Test (Text, From, Current, Taken);
                     if not Taken then
                        return;
                     end if;
                     if Current.Operator = Compare_None then
                        Current.Left := (others => <>);
                        Current.Sub_At := Held;
                     end if;
                  end if;
               end;
            else
               Read_Operand (Text, From, Current.Left, Taken);
               if not Taken then
                  return;
               end if;

               Read_Test (Text, From, Current, Taken);
               if not Taken then
                  return;
               end if;
            end if;

            if Result.Clause_Used >= Max_Clauses then
               return;
            end if;
            Result.Clause_Used := Result.Clause_Used + 1;
            Result.Clauses (Result.Clause_Used) := Current;
            Result.Groups (Result.Group_Used).Count :=
              Result.Groups (Result.Group_Used).Count + 1;
         end;

         declare
            Probe : constant Natural := Skip_Spaces (Text, From);
         begin
            if Probe + 2 <= Text'Last
              and then Text (Probe .. Probe + 2) = "and"
            then
               From := Probe + 3;
            elsif Probe + 1 <= Text'Last
              and then Text (Probe .. Probe + 1) = "or"
            then
               --  A chain longer than the table holds: the rest of it,
               --  after this or, as one group of its own -- which is
               --  what it is, or binding loosest.
               if Result.Group_Used >= Max_Conjunctions - 1
                 or else Result.Clause_Used >= Max_Clauses - 1
               then
                  declare
                     Inner : Condition;
                     Good  : Boolean;
                     Held  : Natural;
                  begin
                     From := Probe + 2;
                     Read_Condition (Text, From, Level + 1, Inner, Good);
                     if not Good then
                        return;
                     end if;
                     Keep (Inner, Held);
                     if Held = 0 then
                        return;
                     end if;
                     Result.Group_Used := Result.Group_Used + 1;
                     Result.Clause_Used := Result.Clause_Used + 1;
                     Result.Groups (Result.Group_Used) :=
                       (First => Result.Clause_Used, Count => 1);
                     Result.Clauses (Result.Clause_Used) :=
                       (Sub_At => Held, others => <>);
                     exit;
                  end;
               end if;
               Result.Group_Used := Result.Group_Used + 1;
               Result.Groups (Result.Group_Used) :=
                 (First => Result.Clause_Used + 1, Count => 0);
               From := Probe + 2;
            else
               exit;
            end if;
         end;
      end loop;

      Ok := True;
   end Read_Condition;

   --  Read a whole condition that must fill Text.
   procedure Read_Condition
     (Text   : String;
      Result : out Condition;
      Ok     : out Boolean)
   is
      From : Natural := Text'First;
   begin
      Read_Condition (Text, From, 0, Result, Ok);
      if Ok then
         Ok := Skip_Spaces (Text, From) > Text'Last;
      end if;
   end Read_Condition;

   --  Record a jump that must be patched to the end of the current if.
   procedure Chain_Exit (Position : Natural) is
   begin
      Item.Program.all (Position).Target := Exit_Chain (Depth);
      Exit_Chain (Depth) := Position;
   end Chain_Exit;

   --  Patch every chained jump of the current if to Target.
   procedure Resolve_Exits (Target : Natural) is
      Position : Natural := Exit_Chain (Depth);
   begin
      while Position /= 0 loop
         declare
            Next : constant Natural := Item.Program.all (Position).Target;
         begin
            Item.Program.all (Position).Target := Target;
            Position := Next;
         end;
      end loop;
      Exit_Chain (Depth) := 0;
   end Resolve_Exits;

   --  Emit an instruction that refuses, naming what it refuses. The name
   --  is kept short because it is a label, not a transcript.
   procedure Refuse (What : String; Position : out Natural) is
      Cut    : constant String :=
        What (What'First .. Natural'Min (What'Last, What'First + 47));
      Offset : Natural;
      Length : Natural;
      Stored : Boolean;
   begin
      Position := 0;
      Store_Literal (Cut, Offset, Length, Stored);
      if not Stored then
         Fail (E.Template_Too_Large, "literal");
         return;
      end if;
      Emit ((Op => Op_Unsupported, Offset => Offset, Length => Length,
             others => <>), Position);
   end Refuse;

   --  Handle a set tag: the assignment forms this engine can carry out,
   --  and a refusal standing in for the ones it cannot.
   --  Read the three numbers of a range and keep them as three operands
   --  in a row, answering with the position of the first.
   --
   --  Three in a row rather than three fields, because an instruction
   --  names one operand and this needs three; they are kept together and
   --  read together, and nothing else may be kept between them.
   procedure Read_Range
     (Text  : String;
      First_At : out Natural;
      Ok    : out Boolean)
   is
      Parts : array (1 .. 3) of Operand;
      Filled : Natural := 0;
      Scan   : Natural := Text'First;
      Taken  : Boolean;
      Kept   : Natural;
   begin
      First_At := 0;
      Ok := False;

      while Filled < 3 loop
         Filled := Filled + 1;
         Read_Operand (Text, Scan, Parts (Filled), Taken);
         if not Taken then
            return;
         end if;

         declare
            Next : constant Natural := Skip_Spaces (Text, Scan);
         begin
            if Next > Text'Last then
               exit;
            elsif Text (Next) = ',' then
               Scan := Next + 1;
            else
               return;
            end if;
         end;
      end loop;

      if Skip_Spaces (Text, Scan) <= Text'Last then
         return;
      end if;

      --  range(n) counts from zero to n by one, and range(a, b) steps by
      --  one; only the written numbers are read, and the rest are what
      --  the language says they are.
      if Filled = 1 then
         Parts (2) := Parts (1);
         Parts (1) := (Terms => [1 => (Kind => Term_Literal, others => <>),
                                 others => <>],
                       Count => 1);
         Store_Literal ("0", Parts (1).Terms (1).Offset,
                        Parts (1).Terms (1).Length, Taken);
         if not Taken then
            return;
         end if;
         Filled := 2;
      end if;

      if Filled = 2 then
         Parts (3) := (Terms => [1 => (Kind => Term_Literal, others => <>),
                                 others => <>],
                       Count => 1);
         Store_Literal ("1", Parts (3).Terms (1).Offset,
                        Parts (3).Terms (1).Length, Taken);
         if not Taken then
            return;
         end if;
      end if;

      for Index in 1 .. 3 loop
         Keep (Parts (Index), Kept);
         if Kept = 0 then
            return;
         end if;
         if Index = 1 then
            First_At := Kept;
         end if;
      end loop;

      Ok := True;
   end Read_Range;

   procedure Compile_Set (Text : String) is separate;

   --  Every macro the template defines, by name, before any of it is
   --  read, and every namespace it makes: a macro may call one defined further down, as the language
   --  looks a name up when the call runs. Each gets its place in the
   --  table now and its parameters and entry where it is defined.
   procedure Declare_Macros is
      At_Tag : Natural := Source'First;
   begin
      while At_Tag + 1 <= Source'Last loop
         if Source (At_Tag .. At_Tag + 1) = "{%" then
            declare
               Scan        : Natural := At_Tag + 2;
               First, Last : Natural;
               Stored      : Boolean;
               Added       : Macro;
            begin
               if Scan <= Source'Last and then Source (Scan) in '-' | '+'
               then
                  Scan := Scan + 1;
               end if;
               Read_Word (Source, Scan, First, Last);
               if Last >= First and then Source (First .. Last) = "set"
               then
                  --  A namespace too is known from the start, so that
                  --  a macro above it reads ns.field as the one name.
                  Read_Word (Source, Scan, First, Last);
                  declare
                     After : Natural := Skip_Spaces (Source, Scan);
                  begin
                     if Last >= First
                       and then Is_Plain_Name (Source (First .. Last))
                       and then After <= Source'Last
                       and then Source (After) = '='
                     then
                        After := Skip_Spaces (Source, After + 1);
                        if After + 9 <= Source'Last
                          and then Source (After .. After + 9)
                                   = "namespace("
                        then
                           declare
                              Named : constant Natural :=
                                Slot_Of (Source (First .. Last));
                           begin
                              if Named /= 0 then
                                 Namespaces (Named) := True;
                              end if;
                           end;
                        end if;
                     end if;
                  end;
               elsif Last >= First and then Source (First .. Last) = "macro"
               then
                  Read_Word (Source, Scan, First, Last);
                  if Last >= First
                    and then Is_Plain_Name (Source (First .. Last))
                    and then Macro_Named (Source (First .. Last)) = 0
                    and then Item.Macro_Used < Max_Macros
                  then
                     Store_Literal (Source (First .. Last),
                                    Added.Name.Offset, Added.Name.Length,
                                    Stored);
                     if not Stored then
                        Fail (E.Template_Too_Large, "source");
                        return;
                     end if;
                     Item.Macro_Used := Item.Macro_Used + 1;
                     Item.Macros (Item.Macro_Used) := Added;
                  end if;
               end if;
               At_Tag := Scan;
            end;
         else
            At_Tag := At_Tag + 1;
         end if;
      end loop;
   end Declare_Macros;

   --  Handle one {% ... %} tag.
   --  {% macro name(p, q='x') %}: the jump over the body, the macro's
   --  entry after it, and its parameters read into the table.
   procedure Compile_Macro (Text : String) is separate;

   procedure Compile_Statement (Body_Text : String) is separate;

   Cursor        : Natural := Source'First;
   Literal_Start : Natural := Source'First;
   Trim_Next     : Boolean := False;
   Named         : Boolean := False;

   --  Where the text after a tag begins.
   --
   --  A tag that stands alone on a line was written on a line of its own
   --  to be read, and the line break that ends it belongs to the
   --  template's own shape rather than to what the model is handed: it
   --  is taken off a block tag and left on an expression, which is the
   --  rule the implementation these templates are written for follows.
   --  A tag that asked for the whitespace after it to go has already
   --  said more than this, and is left alone.
   function Line_After (From : Natural; Block : Boolean) return Natural is
   begin
      if not Block or else From > Source'Last then
         return From;
      elsif Source (From) = ASCII.LF then
         return From + 1;
      elsif Source (From) = ASCII.CR and then From < Source'Last
        and then Source (From + 1) = ASCII.LF
      then
         return From + 2;
      else
         return From;
      end if;
   end Line_After;

   --  Emit the literal text accumulated since the last tag.
   --
   --  Trim_Right takes off every kind of whitespace, which is what a tag
   --  written {%- asks for. Line_Left takes off the spaces and tabs that
   --  stand between a tag and the start of its own line, and only those:
   --  a template indents its tags to be read, and the indentation is not
   --  part of what the model is handed. Where something other than
   --  whitespace stands on that line, nothing is taken off, because then
   --  the tag is in the middle of a line the template meant to write.
   procedure Flush_Literal
     (Upto       : Natural;
      Trim_Right : Boolean;
      Line_Left  : Boolean := False) is
      First : Natural := Literal_Start;
      Last  : Natural := Upto;
      Where : Natural;
      Slice_Offset : Natural;
      Slice_Length : Natural;
      Stored : Boolean;
   begin
      if Trim_Next then
         while First <= Last
           and then (Source (First) = ' ' or else Source (First) = ASCII.HT
                     or else Source (First) = ASCII.LF
                     or else Source (First) = ASCII.CR)
         loop
            First := First + 1;
         end loop;
      end if;

      if Trim_Right then
         while Last >= First
           and then (Source (Last) = ' ' or else Source (Last) = ASCII.HT
                     or else Source (Last) = ASCII.LF
                     or else Source (Last) = ASCII.CR)
         loop
            Last := Last - 1;
         end loop;

      elsif Line_Left then
         declare
            Scan : Natural := Last;
         begin
            while Scan >= First
              and then (Source (Scan) = ' '
                        or else Source (Scan) = ASCII.HT)
            loop
               Scan := Scan - 1;
            end loop;

            --  The newline itself stays: what is taken off is the
            --  indentation after it, not the line break before it.
            --  Asked of the source, not of what is left of this text:
            --  jinja2 strips a block tag's indentation where the tag
            --  begins its line in the file, and a tag before it that
            --  took the line break with it -- trim_blocks, or a
            --  dash -- does not make the line begin anywhere else.
            if Scan < Source'First or else Source (Scan) = ASCII.LF then
               Last := Scan;
            end if;
         end;
      end if;

      if Last < First then
         return;
      end if;

      Store_Literal
        (Source (First .. Last), Slice_Offset, Slice_Length, Stored);
      if not Stored then
         Fail (E.Template_Too_Large, "literal");
         return;
      end if;

      Emit ((Op => Op_Text, Offset => Slice_Offset,
             Length => Slice_Length, others => <>), Where);
   end Flush_Literal;

   --  Which names are numbers. A name is worth what it was assigned,
   --  and the language keeps a number a number: "i + 1" where i was set
   --  from a count is a sum, where here every value is text and a "+"
   --  between two texts runs them together. So once the whole template
   --  has been read, every name whose every assignment is a number --
   --  a sum, a count, a length, a counting loop's variable, a copy of
   --  such a name -- is marked a number wherever it is read, and a term
   --  reading it takes part in a sum as a bare number would. A name
   --  assigned text anywhere, bound by any other loop or handed to a
   --  macro is left as text, which is what it always was.
   procedure Mark_Numeric_Names is separate;

begin
   Close (Item);
   Status := E.Success;

   if Source'Length = 0 then
      Status := E.Make (E.Template_Missing);
      return;
   end if;

   if Source'Length > Bounds.Max_Template_Bytes then
      Status := E.Make (E.Template_Too_Large);
      E.Add_Integer
        (Status, "size", Long_Long_Integer (Source'Length), E.Param_Bytes);
      E.Add_Integer
        (Status, "limit", Long_Long_Integer (Bounds.Max_Template_Bytes),
         E.Param_Bytes);
      return;
   end if;

   Item.Program := new Instruction_Array;

   --  The pool holds decoded literals, the names the template uses, and
   --  the labels of the constructs it refuses. Decoding only shortens and
   --  every label is a slice of a tag, so twice the template covers both,
   --  with the name table's own worst case added outright.
   Item.Source :=
     new String (1 .. 2 * Source'Length + Max_Variables * 64 + 64);

   Item.Name_Used := 1;
   Store_Literal
     ("messages", Item.Names (1).Offset, Item.Names (1).Length, Named);
   if not Named then
      Fail (E.Template_Too_Large, "literal");
      return;
   end if;

   --  And the name a message goes by, made now rather than when a
   --  template happens to mention it, so that message.role has one slot
   --  to read whether the binding came from a loop or an assignment.
   Item.Message_Slot := Slot_Of ("message");
   if Item.Message_Slot = 0 then
      Fail (E.Template_Too_Large, "literal");
      return;
   end if;

   Declare_Macros;
   if E.Is_Error (Status) then
      return;
   end if;

   while Cursor <= Source'Last loop
      if Cursor + 1 <= Source'Last
        and then Source (Cursor .. Cursor + 1) = "{#"
      then
         --  A comment. It contributes nothing but its whitespace control,
         --  which is the only reason it cannot simply be skipped.
         declare
            Scan      : Natural := Cursor + 2;
            Trim_Left : constant Boolean :=
              Scan <= Source'Last and then Source (Scan) = '-';
         begin
            while Scan + 1 <= Source'Last
              and then Source (Scan .. Scan + 1) /= "#}"
            loop
               Scan := Scan + 1;
            end loop;

            if Scan + 1 > Source'Last then
               Fail (E.Template_Syntax_Error, "unterminated_comment");
               return;
            end if;

            Flush_Literal
              (Cursor - 1, Trim_Left, Line_Left => not Trim_Left);
            if E.Is_Error (Status) then
               return;
            end if;

            Trim_Next := Scan > Cursor + 2
              and then Source (Scan - 1) = '-';

            Cursor := Line_After (Scan + 2, not Trim_Next);
            Literal_Start := Cursor;
         end;

      elsif Cursor + 1 <= Source'Last
        and then Source (Cursor) = '{'
        and then (Source (Cursor + 1) = '%' or else Source (Cursor + 1) = '{')
      then
         declare
            Statement : constant Boolean := Source (Cursor + 1) = '%';
            Closer    : constant String :=
              (if Statement then "%}" else "}}");
            Body_First : Natural := Cursor + 2;
            Scan       : Natural := Body_First;
            Trim_Left  : Boolean := False;

            --  A tag written {%+ keeps the line it stands on: it is how
            --  a template says that this one indentation is text it
            --  meant to write. One written +%} keeps the line break
            --  after it the same way, which is the language's own
            --  spelling for a block tag whose line break is text.
            Kept_Left  : Boolean := False;
            Kept_Right : Boolean := False;
         begin
            if Body_First <= Source'Last and then Source (Body_First) = '-'
            then
               Trim_Left := True;
               Body_First := Body_First + 1;
            elsif Statement and then Body_First <= Source'Last
              and then Source (Body_First) = '+'
            then
               Kept_Left := True;
               Body_First := Body_First + 1;
            end if;

            --  The closer outside quotes: a string in a tag may hold
            --  "}}" -- a JSON example written into a prompt -- and the
            --  language's own reader reads the string whole first.
            declare
               Quote : Character := ' ';
            begin
               while Scan + 1 <= Source'Last loop
                  if Quote /= ' ' then
                     if Source (Scan) = '\' then
                        Scan := Scan + 1;
                     elsif Source (Scan) = Quote then
                        Quote := ' ';
                     end if;
                  elsif Source (Scan) in ''' | '"' then
                     Quote := Source (Scan);
                  elsif Source (Scan .. Scan + 1) = Closer then
                     exit;
                  end if;
                  Scan := Scan + 1;
               end loop;
            end;

            if Scan + 1 > Source'Last then
               Fail (E.Template_Syntax_Error, "unterminated_tag");
               return;
            end if;

            declare
               Body_Last  : Natural := Scan - 1;

               --  Whether this tag strips what follows it. Decided now,
               --  applied after the text before the tag has been
               --  flushed, because that flush is where the previous
               --  tag's own stripping is carried out.
               Trim_After : Boolean := False;
            begin
               if Body_Last >= Body_First
                 and then Source (Body_Last) = '-'
               then
                  Trim_After := True;
                  Body_Last := Body_Last - 1;
               elsif Statement and then Body_Last >= Body_First
                 and then Source (Body_Last) = '+'
               then
                  Kept_Right := True;
                  Body_Last := Body_Last - 1;
               end if;

               Flush_Literal
                 (Cursor - 1, Trim_Left,
                  Line_Left =>
                    Statement and then not Trim_Left and then not Kept_Left);
               if E.Is_Error (Status) then
                  return;
               end if;
               Trim_Next := Trim_After;

               if Statement
                 and then Model_Runner.Text.Trim
                            (Source (Body_First .. Body_Last)) = "raw"
               then
                  --  Everything up to the endraw is text, tags and all.
                  declare
                     At_End : Natural := Scan + 2;
                     Found  : Natural := 0;
                  begin
                     while At_End + 1 <= Source'Last loop
                        if Source (At_End .. At_End + 1) = "{%" then
                           declare
                              Shut : Natural := At_End + 2;
                           begin
                              while Shut + 1 <= Source'Last
                                and then Source (Shut .. Shut + 1) /= "%}"
                              loop
                                 Shut := Shut + 1;
                              end loop;
                              if Shut + 1 <= Source'Last
                                and then Model_Runner.Text.Trim
                                           (Source (At_End + 2 .. Shut - 1))
                                         in "endraw" | "-endraw" | "endraw-"
                                            | "-endraw-"
                              then
                                 Found := At_End;
                                 Scan := Shut;
                                 exit;
                              end if;
                           end;
                        end if;
                        At_End := At_End + 1;
                     end loop;
                     if Found = 0 then
                        Fail (E.Template_Unbalanced_Block, "raw");
                        return;
                     end if;
                     declare
                        Raw_First : constant Natural :=
                          Line_After (Body_Last + 3, True);
                        Offset, Length : Natural;
                        Stored : Boolean;
                        Where  : Natural;
                     begin
                        if Found > Raw_First then
                           Store_Literal
                             (Source (Raw_First .. Found - 1), Offset,
                              Length, Stored);
                           if not Stored then
                              Fail (E.Template_Too_Large, "literal");
                              return;
                           end if;
                           Emit ((Op => Op_Text, Offset => Offset,
                                  Length => Length, others => <>), Where);
                           if Where = 0 then
                              return;
                           end if;
                        end if;
                     end;
                  end;
               elsif Statement then
                  Compile_Statement (Source (Body_First .. Body_Last));
                  if E.Is_Error (Status) then
                     return;
                  end if;
               else
                  declare
                     Value : Operand;
                     Valid : Boolean;
                     From  : Natural := Body_First;
                     Where : Natural;
                     Text_Slice : constant String :=
                       Source (Body_First .. Body_Last);
                  begin
                     From := Text_Slice'First;
                     Read_Operand (Text_Slice, From, Value, Valid);

                     --  An expression this engine cannot read becomes an
                     --  instruction that refuses when it is reached. That
                     --  is where raise_exception ends up, and where it
                     --  belongs: the template asked for a failure there,
                     --  and a template that never goes there asked for
                     --  nothing.
                     if not Valid
                       or else Skip_Spaces (Text_Slice, From)
                               <= Text_Slice'Last
                     then
                        --  Or a test or comparison written in the
                        --  output, "x is defined", which is a value
                        --  too.
                        declare
                           Group : Term;
                           Read  : Boolean;
                        begin
                           Read_Value_Group (Text_Slice, Group, Read);
                           if Read then
                              Value := (Terms => [1 => Group, others => <>],
                                        Count => 1);
                              Valid := True;
                           end if;
                        end;
                     end if;

                     if not Valid then
                        Refuse (Text_Slice, Where);
                     else
                        declare
                           Kept : Natural;
                        begin
                           Keep (Value, Kept);

                           if Kept = 0 then
                              Where := 0;
                           else
                              Emit ((Op => Op_Output, Value_At => Kept,
                                     others => <>),
                                    Where);
                           end if;
                        end;
                     end if;

                     if Where = 0 then
                        return;
                     end if;
                  end;
               end if;
            end;

            Cursor :=
              Line_After (Scan + 2,
                          Statement and then not Trim_Next
                          and then not Kept_Right);
            Literal_Start := Cursor;
         end;
      else
         Cursor := Cursor + 1;
      end if;
   end loop;

   Flush_Literal (Source'Last, False);
   if E.Is_Error (Status) then
      return;
   end if;

   if Depth /= 0 then
      Fail (E.Template_Unbalanced_Block, "eof");
      return;
   end if;

   Mark_Numeric_Names;

   Item.Step_Limit := Bounds.Max_Render_Iterations;
   Item.Ready := True;
exception
   when Occurrence : others =>
      Close (Item);
      Status := E.Make (E.Internal_Invariant_Violated);
      E.Add_Frame (Status, "templates.compile");
      E.Add_Frame
        (Status, Ada.Exceptions.Exception_Name (Occurrence));
end Compile;
