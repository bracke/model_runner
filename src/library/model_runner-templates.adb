with Ada.Exceptions;
with Ada.Unchecked_Deallocation;

with Model_Runner.Text;

package body Model_Runner.Templates is

   package E renames Model_Runner.Errors;
   package Conv renames Model_Runner.Conversation;

   use type E.Error_Code;

   procedure Free_Program is
     new Ada.Unchecked_Deallocation (Instruction_Array, Instruction_Access);

   procedure Free_Operands is
     new Ada.Unchecked_Deallocation (Operand_Array, Operand_Array_Access);

   procedure Free_Conditions is
     new Ada.Unchecked_Deallocation (Condition_Array, Condition_Array_Access);
   procedure Free_Text is
     new Ada.Unchecked_Deallocation (String, Text_Access);

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Compiled) is
   begin
      if Item.Program /= null then
         Free_Program (Item.Program);
      end if;
      if Item.Operands /= null then
         Free_Operands (Item.Operands);
      end if;
      if Item.Conditions /= null then
         Free_Conditions (Item.Conditions);
      end if;
      if Item.Source /= null then
         Free_Text (Item.Source);
      end if;
      Item.Program_Used := 0;
      Item.Operand_Used := 0;
      Item.Condition_Used := 0;
      Item.Source_Used := 0;
      Item.Ready := False;
   exception
      when others =>
         Item.Ready := False;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Compiled) is
   begin
      Close (Item);
   end Finalize;

   -------------------
   -- Is_Compiled --
   -------------------

   function Is_Compiled (Item : Compiled) return Boolean is (Item.Ready);

   ---------------------------------------------------------------------------
   --  Compilation
   ---------------------------------------------------------------------------

   --  What kind of block an open nesting level is, so that a closing tag can
   --  be checked against it.
   type Block_Kind is (Block_For, Block_If);

   type Frame is record
      Kind        : Block_Kind := Block_If;
      Start       : Natural := 0;   --  Op_For_Begin, or the branch test
      Pending     : Natural := 0;   --  branch test whose target is unresolved
      Exit_Count  : Natural := 0;   --  number of recorded end-of-if jumps
      Exits       : Natural := 0;   --  first recorded jump; they chain

      --  A loop over something this engine cannot iterate. Its body is
      --  compiled so that the block structure stays readable, and is reached
      --  only through the refusal that stands in its head, which is to say
      --  never.
      Dead        : Boolean := False;
   end record;

   type Frame_Array is array (1 .. Max_Depth) of Frame;

   --------------
   -- Built_In --
   --------------

   function Built_In (Name : String) return String is
      LF : constant Character := Character'Val (10);
   begin
      --  Answered through the enumeration, so a format added there and not
      --  here is a missing case rather than a name that silently carries
      --  nothing.
      if Name = Format_Name (Format_Llama3) then
         return
           "{{ bos_token }}"
           & "{% for message in messages %}"
           & "<|start_header_id|>{{ message['role'] }}<|end_header_id|>"
           & LF & LF
           & "{{ message['content'] }}<|eot_id|>"
           & "{% endfor %}"
           & "{% if add_generation_prompt %}"
           & "<|start_header_id|>assistant<|end_header_id|>" & LF & LF
           & "{% endif %}";

      elsif Name = Format_Name (Format_ChatML) then
         return
           "{% for message in messages %}"
           & "<|im_start|>{{ message['role'] }}" & LF
           & "{{ message['content'] }}<|im_end|>" & LF
           & "{% endfor %}"
           & "{% if add_generation_prompt %}"
           & "<|im_start|>assistant" & LF
           & "{% endif %}";
      else
         return "";
      end if;
   end Built_In;

   procedure Compile
     (Item   : in out Compiled;
      Source : String;
      Bounds : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Status : out E.Error_Info)
   is
      Frames : Frame_Array := [others => <>];
      Depth  : Natural := 0;

      --  Jump instructions that must be patched to the end of the enclosing
      --  if. Chained through the Target field so that no extra storage grows
      --  with the template.
      Exit_Chain : array (1 .. Max_Depth) of Natural := [others => 0];

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
            if Letter = '.' then
               return False;
            end if;
         end loop;
         return True;
      end Is_Plain_Name;

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
         return Item.Name_Used;
      end Slot_Of;

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

      --  Read one term without its filter. Terms are the only values the
      --  engine knows; anything else reads as unsupported.
      procedure Read_Bare_Term
        (Text   : String;
         From   : in out Natural;
         Result : out Term;
         Ok     : out Boolean)
      is
         Index : Natural := Skip_Spaces (Text, From);
      begin
         Result := (others => <>);
         Ok := False;

         if Index > Text'Last then
            return;
         end if;

         if Text (Index) = ''' or else Text (Index) = '"' then
            declare
               Quote   : constant Character := Text (Index);
               Decoded : String (1 .. Text'Length);
               Filled  : Natural := 0;
               Stored  : Boolean;
            begin
               Index := Index + 1;
               while Index <= Text'Last and then Text (Index) /= Quote loop
                  if Text (Index) = '\' and then Index < Text'Last then
                     Index := Index + 1;
                     Filled := Filled + 1;
                     case Text (Index) is
                        when 'n'    => Decoded (Filled) := ASCII.LF;
                        when 't'    => Decoded (Filled) := ASCII.HT;
                        when 'r'    => Decoded (Filled) := ASCII.CR;
                        when others => Decoded (Filled) := Text (Index);
                     end case;
                  else
                     Filled := Filled + 1;
                     Decoded (Filled) := Text (Index);
                  end if;
                  Index := Index + 1;
               end loop;

               if Index > Text'Last then
                  return;
               end if;

               Index := Index + 1;
               Result.Kind := Term_Literal;
               Store_Literal
                 (Decoded (1 .. Filled), Result.Offset, Result.Length, Stored);
               Ok := Stored;
               From := Index;
               return;
            end;
         end if;

         --  A number is only ever compared or emitted, never arithmetic, so
         --  its text is all the engine needs of it.
         if Text (Index) in '0' .. '9' then
            declare
               Start  : constant Natural := Index;
               Stored : Boolean;
            begin
               while Index <= Text'Last and then Text (Index) in '0' .. '9' loop
                  Index := Index + 1;
               end loop;
               Result.Kind := Term_Literal;
               Store_Literal
                 (Text (Start .. Index - 1), Result.Offset, Result.Length,
                  Stored);
               Ok := Stored;
               From := Index;
               return;
            end;
         end if;

         declare
            First, Last : Natural;
         begin
            From := Index;
            Read_Word (Text, From, First, Last);
            if Last < First then
               return;
            end if;

            declare
               Word : constant String := Text (First .. Last);
               Tail : Natural := Skip_Spaces (Text, From);
            begin
               --  message['role'] and message['content'] use bracket syntax;
               --  message.role and message.content use dotted syntax. Both are
               --  accepted because real templates use both.
               if Word = "message" and then Tail <= Text'Last
                 and then Text (Tail) = '['
               then
                  declare
                     Close_Bracket : Natural := Tail;
                  begin
                     while Close_Bracket <= Text'Last
                       and then Text (Close_Bracket) /= ']'
                     loop
                        Close_Bracket := Close_Bracket + 1;
                     end loop;
                     if Close_Bracket > Text'Last then
                        return;
                     end if;

                     declare
                        Field : constant String :=
                          Model_Runner.Text.Trim (Text (Tail + 1 .. Close_Bracket - 1));
                     begin
                        if Field = "'role'" or else Field = """role""" then
                           Result.Kind := Term_Message_Role;
                        elsif Field = "'content'" or else Field = """content"""
                        then
                           Result.Kind := Term_Message_Content;
                        else
                           return;
                        end if;
                     end;
                     From := Close_Bracket + 1;
                     Ok := True;
                     return;
                  end;
               end if;

               --  A message named by position: messages[0]['role'] and the
               --  like. Templates use it to ask whether the conversation
               --  already opens with a system message before adding one,
               --  which is the only construct standing between this engine
               --  and the templates modern models ship.
               if Word /= "message" and then From <= Text'Last
                 and then Text (From) = '['
               then
                  declare
                     Digits_At : Natural := From + 1;
                     Index     : Natural := 0;
                     Close     : Natural;
                  begin
                     while Digits_At <= Text'Last
                       and then Text (Digits_At) in '0' .. '9'
                     loop
                        Index := Index * 10
                          + Character'Pos (Text (Digits_At)) - Character'Pos ('0');
                        Digits_At := Digits_At + 1;
                     end loop;

                     if Digits_At = From + 1
                       or else Digits_At > Text'Last
                       or else Text (Digits_At) /= ']'
                     then
                        return;
                     end if;

                     Close := Digits_At + 1;
                     if Close > Text'Last or else Text (Close) /= '[' then
                        return;
                     end if;

                     declare
                        Shut : Natural := Close + 1;
                     begin
                        while Shut <= Text'Last and then Text (Shut) /= ']'
                        loop
                           Shut := Shut + 1;
                        end loop;
                        if Shut > Text'Last then
                           return;
                        end if;

                        declare
                           Field : constant String :=
                             Model_Runner.Text.Trim
                               (Text (Close + 1 .. Shut - 1));
                        begin
                           if Field = "'role'" or else Field = """role""" then
                              Result.Kind := Term_Indexed_Role;
                           elsif Field = "'content'"
                             or else Field = """content"""
                           then
                              Result.Kind := Term_Indexed_Content;
                           else
                              return;
                           end if;
                        end;
                        --  Which list, so that a template that rebinds the
                        --  name reads the rebound one.
                        Result.Offset := Index;
                        Result.Length := Slot_Of (Word);
                        if Result.Length = 0 then
                           Result := Refused (Word);
                        end if;
                        From := Shut + 1;
                        Ok := True;
                        return;
                     end;
                  end;
               end if;

               if Word = "message.role" then
                  Result.Kind := Term_Message_Role;
               elsif Word = "message.content" then
                  Result.Kind := Term_Message_Content;
               elsif Word = "bos_token" then
                  Result.Kind := Term_Beginning_Token;
               elsif Word = "eos_token" then
                  Result.Kind := Term_End_Token;
               elsif Word = "add_generation_prompt" then
                  Result.Kind := Term_Generation_Prompt;
               elsif Word = "loop.first" then
                  Result.Kind := Term_Loop_First;
               elsif Word = "loop.last" then
                  Result.Kind := Term_Loop_Last;
               elsif Word = "loop.index0" then
                  Result.Kind := Term_Loop_Index_Zero;
               elsif Word = "loop.index" then
                  Result.Kind := Term_Loop_Index_One;
               elsif Word = "true" then
                  Result.Kind := Term_True;
               elsif Word = "false" then
                  Result.Kind := Term_False;
               elsif Word = "none" then
                  Result.Kind := Term_None;
               elsif Is_Plain_Name (Word) then
                  --  A name the template gives itself. Reading one it never
                  --  assigned is an error at the point of reading, not here:
                  --  'is defined' exists precisely to ask about names that
                  --  were never assigned, and answering it is not the same as
                  --  answering what they hold.
                  Result.Kind := Term_Variable;
                  Result.Offset := Slot_Of (Word);
                  if Result.Offset = 0 then
                     Result := Refused (Word);
                  end if;
               else
                  --  A field of something, or a word this engine has never
                  --  heard of. Either way it is a name that means nothing
                  --  here, which is a different mistake from a construct.
                  Result := Refused (Word, E.Template_Unknown_Variable);
               end if;

               Ok := True;
               Tail := 0;
               pragma Unreferenced (Tail);
            end;
         end;
      end Read_Bare_Term;

      --  Read a term and whatever filter follows it.
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

         while Skip_Spaces (Text, From) <= Text'Last
           and then Text (Skip_Spaces (Text, From)) = '|'
         loop
            declare
               Scan        : Natural := Skip_Spaces (Text, From) + 1;
               First, Last : Natural;
            begin
               Read_Word (Text, Scan, First, Last);
               From := Scan;

               if Last < First or else Result.Filter /= Filter_None then
                  Result := Refused ("filter", E.Template_Unknown_Filter);
               elsif Text (First .. Last) = "trim" then
                  Result.Filter := Filter_Trim;
               elsif Text (First .. Last) = "length" then
                  Result.Filter := Filter_Length;
               else
                  Result :=
                    Refused (Text (First .. Last), E.Template_Unknown_Filter);
               end if;
            end;
         end loop;
      end Read_Term;

      --  Read a '+'-joined run of terms.
      procedure Read_Operand
        (Text   : String;
         From   : in out Natural;
         Result : out Operand;
         Ok     : out Boolean)
      is
         Value : Term;
         Taken : Boolean;
      begin
         Result := (others => <>);
         Ok := False;

         loop
            Read_Term (Text, From, Value, Taken);
            exit when not Taken;

            if Result.Count >= Max_Terms then
               return;
            end if;
            Result.Count := Result.Count + 1;
            Result.Terms (Result.Count) := Value;

            declare
               Next : constant Natural := Skip_Spaces (Text, From);
            begin
               exit when Next > Text'Last or else Text (Next) /= '+';
               From := Next + 1;
            end;
         end loop;

         Ok := Result.Count > 0;
      end Read_Operand;

      --  Read whatever follows a clause's left operand: a comparison, an
      --  'is' test, an 'in' test, or nothing at all.
      procedure Read_Test
        (Text    : String;
         From    : in out Natural;
         Current : in out Clause;
         Ok      : out Boolean)
      is
         Probe : constant Natural := Skip_Spaces (Text, From);
         Taken : Boolean;
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

               elsif Text (First .. Last) = "in" then
                  From := Scan;
                  Read_Word (Text, Scan, First, Last);
                  if Last < First then
                     return;
                  end if;
                  From := Scan;

                  if Text (First .. Last) = "message" then
                     Current.Operator := Compare_In_Message;
                  else
                     Current.Left :=
                       (Terms => [1 => Refused (Text (First .. Last)),
                                  others => <>],
                        Count => 1);
                     Current.Operator := Compare_None;
                  end if;

               else
                  From := Restore;
               end if;
            end;
         end if;

         if Current.Operator in Compare_Equal | Compare_Not_Equal then
            Read_Operand (Text, From, Current.Right, Taken);
            Ok := Taken;
         end if;
      end Read_Test;

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
               if Probe <= Text'Last and then Text (Probe) = '(' then
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
                     Current.Sub_At := Held;
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
                  if Result.Group_Used >= Max_Conjunctions then
                     return;
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
      procedure Compile_Set (Text : String) is
         Scan        : Natural := Text'First;
         First, Last : Natural;
         Target      : Natural := 0;
         Where       : Natural;
      begin
         Read_Word (Text, Scan, First, Last);
         if Last >= First and then Is_Plain_Name (Text (First .. Last)) then
            Target := Slot_Of (Text (First .. Last));
         end if;

         declare
            Equals : constant Natural := Skip_Spaces (Text, Scan);
         begin
            if Target = 0
              or else Equals > Text'Last
              or else Text (Equals) /= '='
              or else (Equals < Text'Last and then Text (Equals + 1) = '=')
            then
               Refuse (Text, Where);
               return;
            end if;

            declare
               Rest : constant String :=
                 Model_Runner.Text.Trim (Text (Equals + 1 .. Text'Last));
               Head : Natural := Rest'First;
               Name : Natural := 0;
            begin
               if Rest = "none" then
                  Emit ((Op => Op_Set_None, Offset => Target, others => <>),
                        Where);
                  return;
               end if;

               --  The keywords are values, not names: taking true for a name
               --  copies an undefined slot, and the template that set it then
               --  looks like one reading a variable it never assigned.
               Read_Word (Rest, Head, First, Last);
               if Last >= First
                 and then Is_Plain_Name (Rest (First .. Last))
                 and then Rest (First .. Last) not in "true" | "false" | "none"
               then
                  Name := Slot_Of (Rest (First .. Last));
               end if;

               --  A whole list under a second name. Assigning the value
               --  rather than its text is what lets a template rename the
               --  message list and then loop over the new name.
               if Name /= 0 and then Skip_Spaces (Rest, Head) > Rest'Last then
                  Emit ((Op => Op_Set_Copy, Offset => Target, Target => Name,
                         others => <>), Where);
                  return;
               end if;

               --  A list with a leading slice removed: messages[1:] and its
               --  like. Only a front slice is supported, because that is what
               --  a template does when it lifts the system message out of the
               --  conversation before looping over the rest.
               if Name /= 0 and then Head <= Rest'Last
                 and then Rest (Head) = '['
               then
                  declare
                     Digits_At : Natural := Head + 1;
                     Dropped   : Natural := 0;
                  begin
                     while Digits_At <= Rest'Last
                       and then Rest (Digits_At) in '0' .. '9'
                     loop
                        Dropped := Dropped * 10
                          + Character'Pos (Rest (Digits_At))
                          - Character'Pos ('0');
                        Digits_At := Digits_At + 1;
                     end loop;

                     --  Only a slice, and only a whole one. Anything else
                     --  starting with a bracket -- messages[0]['content'],
                     --  most of all -- is an expression, and falls through
                     --  to be read as one.
                     if Digits_At > Head + 1
                       and then Digits_At + 1 <= Rest'Last
                       and then Rest (Digits_At .. Digits_At + 1) = ":]"
                       and then Skip_Spaces (Rest, Digits_At + 2) > Rest'Last
                     then
                        Emit ((Op => Op_Set_Slice, Offset => Target,
                               Target => Name, Length => Dropped,
                               others => <>), Where);
                        return;
                     end if;
                  end;
               end if;

               declare
                  Value : Operand;
                  Valid : Boolean;
                  From  : Natural := Rest'First;
                  Kept  : Natural;
               begin
                  Read_Operand (Rest, From, Value, Valid);
                  if not Valid
                    or else Skip_Spaces (Rest, From) <= Rest'Last
                  then
                     Refuse (Text, Where);
                     return;
                  end if;

                  Keep (Value, Kept);
                  if Kept = 0 then
                     return;
                  end if;
                  Emit ((Op => Op_Set_Text, Offset => Target,
                         Value_At => Kept, others => <>), Where);
               end;
            end;
         end;
      end Compile_Set;

      --  Handle one {% ... %} tag.
      procedure Compile_Statement (Body_Text : String) is
         Trimmed : constant String := Model_Runner.Text.Trim (Body_Text);
         Where   : Natural;
      begin
         if Trimmed = "" then
            Fail (E.Template_Syntax_Error, "empty_tag");
            return;
         end if;

         if Model_Runner.Text.Starts_With (Trimmed, "for ") then
            declare
               Rest : constant String :=
                 Model_Runner.Text.Trim (Trimmed (Trimmed'First + 4 .. Trimmed'Last));
               Over : Natural := 0;
               Scan : Natural := Rest'First;
               First, Last : Natural;
            begin
               --  The loop variable is always named message, because the
               --  fields this engine can read from an iterate are a message's
               --  fields. Any other loop is compiled but refuses if reached.
               Read_Word (Rest, Scan, First, Last);
               if Last >= First and then Rest (First .. Last) = "message" then
                  Read_Word (Rest, Scan, First, Last);
                  if Last >= First and then Rest (First .. Last) = "in" then
                     Read_Word (Rest, Scan, First, Last);
                     if Last >= First
                       and then Skip_Spaces (Rest, Scan) > Rest'Last
                       and then Is_Plain_Name (Rest (First .. Last))
                     then
                        Over := Slot_Of (Rest (First .. Last));
                     end if;
                  end if;
               end if;

               if Depth >= Max_Depth then
                  Fail (E.Template_Nesting_Too_Deep, "for");
                  return;
               end if;

               if Over = 0 then
                  Refuse (Rest, Where);
               else
                  Emit ((Op => Op_For_Begin, Offset => Over, others => <>),
                        Where);
               end if;
               if Where = 0 then
                  return;
               end if;

               Depth := Depth + 1;
               Frames (Depth) :=
                 (Kind => Block_For, Start => Where, Dead => Over = 0,
                  others => <>);
               Exit_Chain (Depth) := 0;
            end;

         elsif Trimmed = "endfor" then
            if Depth = 0 or else Frames (Depth).Kind /= Block_For then
               Fail (E.Template_Unbalanced_Block, "endfor");
               return;
            end if;

            if not Frames (Depth).Dead then
               Emit ((Op => Op_For_Next,
                      Target => Frames (Depth).Start, others => <>), Where);
               if Where = 0 then
                  return;
               end if;
               Item.Program.all (Frames (Depth).Start).Target := Where + 1;
            end if;
            Depth := Depth - 1;

         elsif Model_Runner.Text.Starts_With (Trimmed, "set ") then
            Compile_Set
              (Model_Runner.Text.Trim
                 (Trimmed (Trimmed'First + 4 .. Trimmed'Last)));

         elsif Model_Runner.Text.Starts_With (Trimmed, "if ") then
            declare
               Test  : Condition;
               Valid : Boolean;
            begin
               Read_Condition
                 (Model_Runner.Text.Trim (Trimmed (Trimmed'First + 3 .. Trimmed'Last)),
                  Test, Valid);
               if not Valid then
                  Fail (E.Template_Unsupported_Construct, "if");
                  return;
               end if;

               if Depth >= Max_Depth then
                  Fail (E.Template_Nesting_Too_Deep, "if");
                  return;
               end if;

               declare
                  Held : Natural;
               begin
                  Keep (Test, Held);

                  --  Keeping can fail on the same bound Emit reports, and
                  --  failing releases the program, so nothing may be emitted
                  --  after it.
                  if Held = 0 then
                     Where := 0;
                  else
                     Emit ((Op => Op_Jump_If_False, Test_At => Held,
                            others => <>), Where);
                  end if;
               end;
               if Where = 0 then
                  return;
               end if;

               Depth := Depth + 1;
               Frames (Depth) :=
                 (Kind => Block_If, Start => Where, Pending => Where, others => <>);
               Exit_Chain (Depth) := 0;
            end;

         elsif Model_Runner.Text.Starts_With (Trimmed, "elif ") then
            declare
               Test  : Condition;
               Valid : Boolean;
               Jump  : Natural;
            begin
               if Depth = 0 or else Frames (Depth).Kind /= Block_If then
                  Fail (E.Template_Unbalanced_Block, "elif");
                  return;
               end if;

               Read_Condition
                 (Model_Runner.Text.Trim (Trimmed (Trimmed'First + 5 .. Trimmed'Last)),
                  Test, Valid);
               if not Valid then
                  Fail (E.Template_Unsupported_Construct, "elif");
                  return;
               end if;

               --  There is a jump to patch only while the block still has an
               --  untaken branch. After an else there is none, and an elif
               --  following one is a template that does not mean anything.
               if Frames (Depth).Pending = 0 then
                  Fail (E.Template_Unbalanced_Block, "elif");
                  return;
               end if;

               Emit ((Op => Op_Jump, others => <>), Jump);
               if Jump = 0 then
                  return;
               end if;
               Chain_Exit (Jump);

               Item.Program.all (Frames (Depth).Pending).Target :=
                 Item.Program_Used + 1;

               declare
                  Held : Natural;
               begin
                  Keep (Test, Held);

                  --  Keeping can fail on the same bound Emit reports, and
                  --  failing releases the program, so nothing may be emitted
                  --  after it.
                  if Held = 0 then
                     Where := 0;
                  else
                     Emit ((Op => Op_Jump_If_False, Test_At => Held,
                            others => <>), Where);
                  end if;
               end;
               if Where = 0 then
                  return;
               end if;
               Frames (Depth).Pending := Where;
            end;

         elsif Trimmed = "else" then
            declare
               Jump : Natural;
            begin
               if Depth = 0 or else Frames (Depth).Kind /= Block_If then
                  Fail (E.Template_Unbalanced_Block, "else");
                  return;
               end if;

               --  A second else has no branch left to close.
               if Frames (Depth).Pending = 0 then
                  Fail (E.Template_Unbalanced_Block, "else");
                  return;
               end if;

               Emit ((Op => Op_Jump, others => <>), Jump);
               if Jump = 0 then
                  return;
               end if;
               Chain_Exit (Jump);

               Item.Program.all (Frames (Depth).Pending).Target :=
                 Item.Program_Used + 1;
               Frames (Depth).Pending := 0;
            end;

         elsif Trimmed = "endif" then
            if Depth = 0 or else Frames (Depth).Kind /= Block_If then
               Fail (E.Template_Unbalanced_Block, "endif");
               return;
            end if;

            if Frames (Depth).Pending /= 0 then
               Item.Program.all (Frames (Depth).Pending).Target :=
                 Item.Program_Used + 1;
            end if;
            Resolve_Exits (Item.Program_Used + 1);
            Depth := Depth - 1;

         else
            --  set, macro, include, import, raise_exception and everything
            --  else the format allows are outside the supported subset.
            declare
               Head : Natural := Trimmed'First;
            begin
               while Head <= Trimmed'Last
                 and then Trimmed (Head) /= ' '
               loop
                  Head := Head + 1;
               end loop;
               Fail (E.Template_Unsupported_Construct,
                     Trimmed (Trimmed'First .. Head - 1));
            end;
         end if;
      end Compile_Statement;

      Cursor        : Natural := Source'First;
      Literal_Start : Natural := Source'First;
      Trim_Next     : Boolean := False;
      Named         : Boolean := False;

      --  Emit the literal text accumulated since the last tag.
      procedure Flush_Literal (Upto : Natural; Trim_Right : Boolean) is
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

               Trim_Next := Scan > Cursor + 2
                 and then Source (Scan - 1) = '-';

               Flush_Literal (Cursor - 1, Trim_Left);
               if E.Is_Error (Status) then
                  return;
               end if;

               Cursor := Scan + 2;
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
            begin
               if Body_First <= Source'Last and then Source (Body_First) = '-'
               then
                  Trim_Left := True;
                  Body_First := Body_First + 1;
               end if;

               while Scan + 1 <= Source'Last
                 and then Source (Scan .. Scan + 1) /= Closer
               loop
                  Scan := Scan + 1;
               end loop;

               if Scan + 1 > Source'Last then
                  Fail (E.Template_Syntax_Error, "unterminated_tag");
                  return;
               end if;

               declare
                  Body_Last : Natural := Scan - 1;
               begin
                  if Body_Last >= Body_First
                    and then Source (Body_Last) = '-'
                  then
                     Trim_Next := True;
                     Body_Last := Body_Last - 1;
                  else
                     Trim_Next := False;
                  end if;

                  Flush_Literal (Cursor - 1, Trim_Left);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  if Statement then
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

               Cursor := Scan + 2;
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

   ---------------------------------------------------------------------------
   --  Rendering
   ---------------------------------------------------------------------------

   procedure Render
     (Item                  : Compiled;
      Messages              : Conv.History;
      Beginning_Token       : String;
      End_Token             : String;
      Add_Generation_Prompt : Boolean;
      Target                : out String;
      Last                  : out Natural;
      Status                : out E.Error_Info)
   is
      Count      : constant Natural := Conv.Length (Messages);
      Position   : Natural := 1;
      Current    : Natural := 0;
      Loop_Start : Positive := 1;
      Iterations : Natural := 0;
      Overflow   : Boolean := False;

      --  What a name holds. A list is held as the position it starts at,
      --  because the only thing a template does to one is drop entries from
      --  the front of it.
      type Value_Kind is (Value_Undefined, Value_Text, Value_None, Value_List);

      type Slot is record
         Kind   : Value_Kind := Value_Undefined;
         Offset : Natural := 0;
         Length : Natural := 0;
         Start  : Positive := 1;
      end record;

      Slots : array (1 .. Max_Variables) of Slot := [others => <>];

      --  Text the template has assigned to names. Sized against the output
      --  rather than fixed, because what goes in here is mostly message
      --  content on its way out.
      Pool_Size : constant Natural :=
        Natural'Min (Max_Variable_Bytes, Natural'Max (Target'Length, 1024));
      Pool      : String (1 .. Pool_Size) := [others => ' '];
      Pool_Used : Natural := 0;

      --  Set when the render reaches something the compiler carried through
      --  rather than answered. Reported like overflow, after the step.
      Refused     : Boolean := False;
      Refused_At  : Natural := 0;
      Refused_Len : Natural := 0;
      Refused_Why : E.Error_Code := E.Template_Unsupported_Construct;

      --  Refuse, naming a slice of the compiled source pool. The first
      --  refusal is the one reported: a condition can hold several terms and
      --  the reader wants the one that stopped it, not the last one looked at.
      procedure Refuse
        (Offset : Natural; Length : Natural; Why : E.Error_Code) is
      begin
         if not Refused then
            Refused := True;
            Refused_At := Offset;
            Refused_Len := Length;
            Refused_Why := Why;
         end if;
      end Refuse;

      --  Append text to the output, reporting overflow once.
      procedure Put (Value : String) is
      begin
         if Overflow or else Value'Length = 0 then
            return;
         end if;
         if Last + Value'Length > Target'Length then
            Overflow := True;
            return;
         end if;
         Target (Target'First + Last .. Target'First + Last + Value'Length - 1) :=
           Value;
         Last := Last + Value'Length;
      end Put;

      --  Value of one term in the current context, before its filter.
      function Raw_Of (Value : Term) return String is
      begin
         case Value.Kind is
            when Term_Literal =>
               return Item.Source.all
                 (Value.Offset + 1 .. Value.Offset + Value.Length);
            when Term_Beginning_Token =>
               return Beginning_Token;
            when Term_End_Token =>
               return End_Token;
            when Term_Message_Role =>
               return (if Current = 0 then ""
                       else Conv.Role_Name (Conv.Sender_At (Messages, Current)));
            when Term_Message_Content =>
               return (if Current = 0 then ""
                       else Conv.Content_At (Messages, Current));
            when Term_Indexed_Role | Term_Indexed_Content =>
               --  Counted from zero in the template and from one here, and
               --  from wherever the list it names begins, which a template
               --  moves when it lifts the system message out. A position the
               --  conversation does not reach is empty rather than an error,
               --  which is what a template comparing it against a role name
               --  expects.
               declare
                  Holder : Slot renames Slots (Value.Length);
                  At_Message : constant Natural :=
                    Holder.Start + Value.Offset;
               begin
                  if Holder.Kind /= Value_List then
                     Refuse (0, 0, E.Template_Unsupported_Construct);
                     return "";
                  elsif At_Message > Count then
                     return "";
                  elsif Value.Kind = Term_Indexed_Role then
                     return Conv.Role_Name
                       (Conv.Sender_At (Messages, At_Message));
                  else
                     return Conv.Content_At (Messages, At_Message);
                  end if;
               end;
            when Term_Generation_Prompt =>
               return (if Add_Generation_Prompt then "true" else "");
            when Term_Loop_First =>
               return (if Current = Loop_Start then "true" else "");
            when Term_Loop_Last =>
               return (if Current = Count and then Count > 0 then "true" else "");
            when Term_Loop_Index_Zero =>
               return Model_Runner.Text.Image
                 (Long_Long_Integer (Current) - Long_Long_Integer (Loop_Start));
            when Term_Loop_Index_One =>
               return Model_Runner.Text.Image
                 (Long_Long_Integer (Current) - Long_Long_Integer (Loop_Start)
                  + 1);
            when Term_True =>
               return "true";
            when Term_False | Term_None =>
               return "";
            when Term_Variable =>
               declare
                  Holder : Slot renames Slots (Value.Offset);
                  Name   : Variable_Name renames Item.Names (Value.Offset);
               begin
                  case Holder.Kind is
                     when Value_Text =>
                        return Pool (Holder.Offset + 1
                                     .. Holder.Offset + Holder.Length);
                     when Value_None =>
                        return "";
                     when Value_Undefined =>
                        Refuse (Name.Offset, Name.Length,
                                E.Template_Unknown_Variable);
                        return "";
                     when Value_List =>
                        --  A list has no text. Asking for one is a template
                        --  doing something this engine does not model, not a
                        --  template asking for the empty string.
                        Refuse (Name.Offset, Name.Length,
                                E.Template_Unsupported_Construct);
                        return "";
                  end case;
               end;
            when Term_Unsupported =>
               Refuse (Value.Offset, Value.Length, Value.Why);
               return "";
         end case;
      end Raw_Of;

      --  Value of one term with its filter applied.
      function Value_Of (Value : Term) return String is
      begin
         case Value.Filter is
            when Filter_None =>
               return Raw_Of (Value);

            when Filter_Trim =>
               return Model_Runner.Text.Trim (Raw_Of (Value));

            when Filter_Length =>
               --  A list's length is the one thing about a list this engine
               --  can answer, so it is answered before the value is asked
               --  for as text.
               if Value.Kind = Term_Variable
                 and then Slots (Value.Offset).Kind = Value_List
               then
                  return Model_Runner.Text.Image
                    (Long_Long_Integer
                       (Integer'Max
                          (Count - Slots (Value.Offset).Start + 1, 0)));
               end if;
               return Model_Runner.Text.Image
                 (Long_Long_Integer (Raw_Of (Value)'Length));
         end case;
      end Value_Of;

      --  Write an operand straight to the output. Emitting term by term
      --  avoids a temporary the size of the whole target, which message
      --  content can legitimately approach.
      procedure Emit_Operand (Value : Operand) is
      begin
         for Index in 1 .. Value.Count loop
            Put (Value_Of (Value.Terms (Index)));
         end loop;
      end Emit_Operand;

      --  Largest operand this engine compares. Conditions in the supported
      --  subset compare roles, short literals and boolean markers; a longer
      --  operand is truncated for the comparison, which can only make a
      --  comparison fail, never wrongly succeed on a shorter prefix.
      Max_Comparison : constant := 1024;

      --  Concatenated value of an operand, for use in a comparison.
      function Value_Of (Value : Operand) return String is
         --  Only the filled prefix is ever returned, but defining the whole
         --  buffer costs a kilobyte on a path that is not hot and removes the
         --  question of whether that is really true.
         Result : String (1 .. Max_Comparison) := [others => ' '];
         Filled : Natural := 0;
      begin
         for Index in 1 .. Value.Count loop
            declare
               Piece : constant String := Value_Of (Value.Terms (Index));
            begin
               if Filled + Piece'Length > Result'Length then
                  return Result (1 .. Filled) & Piece;
               end if;
               Result (Filled + 1 .. Filled + Piece'Length) := Piece;
               Filled := Filled + Piece'Length;
            end;
         end loop;
         return Result (1 .. Filled);
      end Value_Of;

      --  Truth of one clause. A bare operand is true when it is non-empty,
      --  which matches how the supported boolean terms are written.
      function Truth_Of (Value : Condition) return Boolean;

      --  Whether a name has been given a value on the path taken so far.
      --  Asking is not reading: a name the template never assigns is a name
      --  this answers False about, and reading it stays an error.
      function Is_Defined (Value : Operand) return Boolean is
      begin
         if Value.Count /= 1 then
            return False;
         end if;
         case Value.Terms (1).Kind is
            when Term_Variable =>
               return Slots (Value.Terms (1).Offset).Kind /= Value_Undefined;
            when Term_Unsupported =>
               return False;
            when others =>
               return True;
         end case;
      end Is_Defined;

      --  Whether a name holds none.
      function Is_None (Value : Operand) return Boolean is
      begin
         return Value.Count = 1
           and then ((Value.Terms (1).Kind = Term_Variable
                      and then Slots (Value.Terms (1).Offset).Kind = Value_None)
                     or else Value.Terms (1).Kind = Term_None);
      end Is_None;

      function Truth_Of (Value : Clause) return Boolean is
         Result : Boolean;
      begin
         if Value.Sub_At /= 0 then
            Result := Truth_Of (Item.Conditions.all (Value.Sub_At));
            return (if Value.Negated then not Result else Result);
         end if;

         case Value.Operator is
            when Compare_None =>
               Result := Value_Of (Value.Left) /= "";

            when Compare_Equal | Compare_Not_Equal =>
               declare
                  Left  : constant String := Value_Of (Value.Left);
                  Right : constant String := Value_Of (Value.Right);
               begin
                  Result :=
                    (if Value.Operator = Compare_Equal
                     then Left = Right
                     else Left /= Right);
               end;

            when Compare_Defined =>
               Result := Is_Defined (Value.Left);

            when Compare_Not_Defined =>
               Result := not Is_Defined (Value.Left);

            when Compare_Is_None =>
               Result := Is_None (Value.Left);

            when Compare_Is_Not_None =>
               Result := not Is_None (Value.Left);

            when Compare_In_Message =>
               --  The fields a message has here. A template asking after any
               --  other one -- tool_calls, most often -- is asking about a
               --  message this engine cannot hold, and the honest answer is
               --  that this message does not have it.
               declare
                  Field : constant String := Value_Of (Value.Left);
               begin
                  Result := Field = "role" or else Field = "content";
               end;
         end case;

         return (if Value.Negated then not Result else Result);
      end Truth_Of;

      --  Truth of a whole condition: any conjunction being true is enough.
      function Truth_Of (Value : Condition) return Boolean is
      begin
         for Group in 1 .. Value.Group_Used loop
            declare
               Span : Conjunction renames Value.Groups (Group);
               All_True : Boolean := Span.Count > 0;
            begin
               for Offset in 0 .. Span.Count - 1 loop
                  if not Truth_Of (Value.Clauses (Span.First + Offset)) then
                     All_True := False;
                     exit;
                  end if;
               end loop;
               if All_True then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Truth_Of;

   begin
      Target := [others => ' '];
      Last := 0;
      Status := E.Success;

      if not Item.Ready then
         Status := E.Make (E.Template_Missing);
         return;
      end if;

      --  The name messages starts out meaning the whole conversation. A
      --  template that never assigns anything sees exactly what it did
      --  before this table existed.
      Slots (1) := (Kind => Value_List, Start => 1, others => <>);

      --  A flat instruction list with jumps: rendering never recurses, so the
      --  only bound needed is on iterations.
      while Position <= Item.Program_Used loop
         Iterations := Iterations + 1;
         if Iterations > Item.Step_Limit then
            Last := 0;
            Status := E.Make (E.Template_Iteration_Limit);
            E.Add_Integer
              (Status, "limit", Long_Long_Integer (Item.Step_Limit));
            return;
         end if;

         declare
            Step : Instruction renames Item.Program.all (Position);
         begin
            case Step.Op is
               when Op_Text =>
                  Put (Item.Source.all
                         (Step.Offset + 1 .. Step.Offset + Step.Length));
                  Position := Position + 1;

               when Op_Output =>
                  Emit_Operand (Item.Operands.all (Step.Value_At));
                  Position := Position + 1;

               when Op_For_Begin =>
                  declare
                     Holder : Slot renames Slots (Step.Offset);
                  begin
                     if Holder.Kind /= Value_List then
                        Refuse (Item.Names (Step.Offset).Offset,
                                Item.Names (Step.Offset).Length,
                                E.Template_Unsupported_Construct);
                        Position := Position + 1;
                     elsif Holder.Start > Count then
                        Position := Step.Target;
                     else
                        Loop_Start := Holder.Start;
                        Current := Holder.Start;
                        Position := Position + 1;
                     end if;
                  end;

               when Op_For_Next =>
                  if Current < Count then
                     Current := Current + 1;
                     Position := Step.Target + 1;
                  else
                     Current := 0;
                     Position := Position + 1;
                  end if;

               when Op_Jump_If_False =>
                  if Truth_Of (Item.Conditions.all (Step.Test_At)) then
                     Position := Position + 1;
                  else
                     Position := Step.Target;
                  end if;

               when Op_Jump =>
                  Position := Step.Target;

               when Op_Set_Text =>
                  declare
                     Value : constant String :=
                       Value_Of (Item.Operands.all (Step.Value_At));
                     Held  : Slot renames Slots (Step.Offset);
                  begin
                     --  A name reassigned in a loop -- which is how a
                     --  template builds one message's text before emitting
                     --  it -- is almost always the newest thing in the pool.
                     --  Taking its room back makes that loop cost what one
                     --  iteration costs instead of what all of them do.
                     --  Value is already a copy, so the old text may go.
                     if Held.Kind = Value_Text
                       and then Held.Offset + Held.Length = Pool_Used
                     then
                        Pool_Used := Held.Offset;
                     end if;

                     if Pool_Used + Value'Length > Pool'Length then
                        Refuse (Item.Names (Step.Offset).Offset,
                                Item.Names (Step.Offset).Length,
                                E.Template_Variables_Too_Large);
                     else
                        Pool (Pool_Used + 1 .. Pool_Used + Value'Length) :=
                          Value;
                        Slots (Step.Offset) :=
                          (Kind => Value_Text, Offset => Pool_Used,
                           Length => Value'Length, Start => 1);
                        Pool_Used := Pool_Used + Value'Length;
                     end if;
                  end;
                  Position := Position + 1;

               when Op_Set_None =>
                  Slots (Step.Offset) := (Kind => Value_None, others => <>);
                  Position := Position + 1;

               when Op_Set_Copy =>
                  Slots (Step.Offset) := Slots (Step.Target);
                  Position := Position + 1;

               when Op_Set_Slice =>
                  if Slots (Step.Target).Kind /= Value_List then
                     Refuse (Item.Names (Step.Target).Offset,
                             Item.Names (Step.Target).Length,
                             E.Template_Unsupported_Construct);
                  else
                     Slots (Step.Offset) :=
                       (Kind  => Value_List,
                        Start => Slots (Step.Target).Start + Step.Length,
                        others => <>);
                  end if;
                  Position := Position + 1;

               when Op_Unsupported =>
                  Refuse (Step.Offset, Step.Length,
                          E.Template_Unsupported_Construct);
                  Position := Position + 1;
            end case;
         end;

         if Refused then
            Last := 0;
            Status := E.Make (Refused_Why);
            if Refused_Why = E.Template_Variables_Too_Large then
               E.Add_Integer
                 (Status, "limit", Long_Long_Integer (Pool'Length),
                  E.Param_Bytes);
            end if;
            if Refused_Len > 0 then
               E.Add_Text
                 (Status, "construct",
                  Item.Source.all
                    (Refused_At + 1 .. Refused_At + Refused_Len),
                  E.Param_Identifier);
            end if;
            return;
         end if;

         if Overflow then
            Last := 0;
            Status := E.Make (E.Template_Output_Too_Large);
            E.Add_Integer
              (Status, "limit", Long_Long_Integer (Target'Length),
               E.Param_Bytes);
            return;
         end if;
      end loop;
   exception
      when Occurrence : others =>
         Last := 0;
         Status := E.Make (E.Internal_Invariant_Violated);
         E.Add_Frame (Status, "templates.render");
         E.Add_Frame
           (Status, Ada.Exceptions.Exception_Name (Occurrence));
   end Render;

end Model_Runner.Templates;
