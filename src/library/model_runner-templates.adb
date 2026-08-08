with Ada.Exceptions;
with Ada.Unchecked_Deallocation;

with Model_Runner.Text;

package body Model_Runner.Templates is

   package E renames Model_Runner.Errors;
   package Conv renames Model_Runner.Conversation;

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
   end record;

   type Frame_Array is array (1 .. Max_Depth) of Frame;

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

      --  Read one term. Terms are the only values the engine knows; anything
      --  else is an unsupported construct.
      procedure Read_Term
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
               else
                  return;
               end if;

               Ok := True;
               Tail := 0;
               pragma Unreferenced (Tail);
            end;
         end;
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

      --  Read a condition: an or-list of and-lists of clauses.
      procedure Read_Condition
        (Text   : String;
         Result : out Condition;
         Ok     : out Boolean)
      is
         From : Natural := Text'First;
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
                           or else Text (Probe + 3) = ' ')
               then
                  Current.Negated := True;
                  From := Probe + 3;
               else
                  From := Probe;
               end if;

               Read_Operand (Text, From, Current.Left, Taken);
               if not Taken then
                  return;
               end if;

               Probe := Skip_Spaces (Text, From);
               if Probe + 1 <= Text'Last
                 and then Text (Probe .. Probe + 1) = "=="
               then
                  Current.Operator := Compare_Equal;
                  From := Probe + 2;
               elsif Probe + 1 <= Text'Last
                 and then Text (Probe .. Probe + 1) = "!="
               then
                  Current.Operator := Compare_Not_Equal;
                  From := Probe + 2;
               end if;

               if Current.Operator /= Compare_None then
                  Read_Operand (Text, From, Current.Right, Taken);
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

         Ok := Skip_Spaces (Text, From) > Text'Last;
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
            begin
               --  Only iteration over the message list is supported. Anything
               --  else would need a general object model.
               if Rest /= "message in messages" then
                  Fail (E.Template_Unsupported_Construct, "for");
                  return;
               end if;

               if Depth >= Max_Depth then
                  Fail (E.Template_Nesting_Too_Deep, "for");
                  return;
               end if;

               Emit ((Op => Op_For_Begin, others => <>), Where);
               if Where = 0 then
                  return;
               end if;

               Depth := Depth + 1;
               Frames (Depth) := (Kind => Block_For, Start => Where, others => <>);
               Exit_Chain (Depth) := 0;
            end;

         elsif Trimmed = "endfor" then
            if Depth = 0 or else Frames (Depth).Kind /= Block_For then
               Fail (E.Template_Unbalanced_Block, "endfor");
               return;
            end if;

            Emit ((Op => Op_For_Next,
                   Target => Frames (Depth).Start, others => <>), Where);
            if Where = 0 then
               return;
            end if;
            Item.Program.all (Frames (Depth).Start).Target := Where + 1;
            Depth := Depth - 1;

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
      --  The literal pool can never need more than the template itself, since
      --  escape decoding only shortens.
      Item.Source := new String (1 .. Source'Length);

      while Cursor <= Source'Last loop
         if Cursor + 1 <= Source'Last
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
                        if not Valid then
                           Fail (E.Template_Unknown_Variable, "output");
                           return;
                        end if;
                        if Skip_Spaces (Text_Slice, From) <= Text_Slice'Last then
                           --  A pipe here is a filter, and saying so is worth
                           --  a code of its own: a reader can act on "this
                           --  template uses a filter" where "unsupported
                           --  expression" leaves them looking for the
                           --  expression.
                           if Text_Slice (Skip_Spaces (Text_Slice, From)) = '|'
                           then
                              Fail (E.Template_Unknown_Filter, "output");
                           else
                              Fail
                                (E.Template_Unsupported_Construct, "expression");
                           end if;
                           return;
                        end if;

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
      Iterations : Natural := 0;
      Overflow   : Boolean := False;

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

      --  Value of one term in the current context.
      function Value_Of (Value : Term) return String is
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
            when Term_Generation_Prompt =>
               return (if Add_Generation_Prompt then "true" else "");
            when Term_Loop_First =>
               return (if Current = 1 then "true" else "");
            when Term_Loop_Last =>
               return (if Current = Count and then Count > 0 then "true" else "");
            when Term_Loop_Index_Zero =>
               return Model_Runner.Text.Image (Long_Long_Integer (Current) - 1);
            when Term_Loop_Index_One =>
               return Model_Runner.Text.Image (Long_Long_Integer (Current));
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
      function Truth_Of (Value : Clause) return Boolean is
         Result : Boolean;
      begin
         if Value.Operator = Compare_None then
            Result := Value_Of (Value.Left) /= "";
         else
            declare
               Left  : constant String := Value_Of (Value.Left);
               Right : constant String := Value_Of (Value.Right);
            begin
               Result :=
                 (if Value.Operator = Compare_Equal
                  then Left = Right
                  else Left /= Right);
            end;
         end if;

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
                  if Count = 0 then
                     Position := Step.Target;
                  else
                     Current := 1;
                     Position := Position + 1;
                  end if;

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
            end case;
         end;

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
