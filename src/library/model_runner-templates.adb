with Ada.Exceptions;
with Ada.Unchecked_Deallocation;

with Model_Runner.Text;

package body Model_Runner.Templates is

   package E renames Model_Runner.Errors;
   package Conv renames Model_Runner.Conversation;

   --  Renamed because Render takes a parameter named Tools, which is what
   --  the template calls them, and the package and the parameter would
   --  otherwise be the same word in the one procedure that needs both.
   package Offered_Tools renames Model_Runner.Tools;

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

   -----------------
   -- Reads_Tools --
   -----------------

   function Reads_Tools (Item : Compiled) return Boolean
   is (Item.Ready and then Item.Tools_Slot /= 0);

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

      --  A loop that counts rather than one that walks a list. The two end
      --  with different instructions, and which one a block ends with is
      --  decided where the block began.
      Numeric     : Boolean := False;

      --  A loop over the tools a caller offered, which ends with an
      --  instruction of its own for the same reason.
      Walks_Tools : Boolean := False;

      --  And a loop over the calls one turn asked for, which is the third
      --  thing there is to walk and ends with the third instruction.
      Walks_Calls : Boolean := False;
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
      elsif Name = Format_Name (Format_Gemma) then
         --  The one format here that calls the assistant something else.
         --  Gemma's turns are "user" and "model", so the role a caller gives
         --  is mapped rather than written through -- which is why this needs
         --  a comparison where the other three need none.
         return
           "{{ bos_token }}"
           & "{% for message in messages %}"
           & "<start_of_turn>"
           & "{% if message['role'] == 'assistant' %}model"
           & "{% else %}{{ message['role'] }}{% endif %}" & LF
           & "{{ message['content'] }}<end_of_turn>" & LF
           & "{% endfor %}"
           & "{% if add_generation_prompt %}"
           & "<start_of_turn>model" & LF
           & "{% endif %}";

      elsif Name = Format_Name (Format_Phi3) then
         return
           "{% for message in messages %}"
           & "<|{{ message['role'] }}|>" & LF
           & "{{ message['content'] }}<|end|>" & LF
           & "{% endfor %}"
           & "{% if add_generation_prompt %}"
           & "<|assistant|>" & LF
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

      --  The names a template has made into namespaces, by slot.
      --
      --  A namespace is a holder with named fields, and the reason templates
      --  use one is that a name assigned inside a loop does not outlive the
      --  loop while a field of a namespace does. Names here outlive
      --  everything already, so a namespace needs no machinery of its own:
      --  ns.field is a name like any other, spelled with a dot. What the set
      --  below is for is telling that name apart from message.role, which is
      --  also spelled with a dot and is not a name at all.
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
      procedure Read_Operand
        (Text   : String;
         From   : in out Natural;
         Result : out Operand;
         Ok     : out Boolean);

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

      Method_Names : constant array (1 .. 4) of Method_Name :=
        [(Strip_Name'Access, Method_Strip),
         (LStrip_Name'Access, Method_Left_Strip),
         (RStrip_Name'Access, Method_Right_Strip),
         (Split_Name'Access, Method_Split_First)];

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
      is
         Scan  : Natural := Skip_Spaces (Text, From);
         Taken : Boolean;
         Kept  : Natural := 0;
         Piece : Operand;
         Doing_Now : Method_Kind := Doing;
      begin
         Ok := False;

         if Scan > Text'Last or else Text (Scan) /= '(' then
            return;
         end if;

         --  The argument, which is a piece of text or nothing at all: strip
         --  with no argument takes whitespace off, as the language says.
         Scan := Skip_Spaces (Text, Scan + 1);
         if Scan <= Text'Last and then Text (Scan) /= ')' then
            Read_Operand (Text, Scan, Piece, Taken);
            if not Taken then
               return;
            end if;
            Keep (Piece, Kept);
            if Kept = 0 then
               return;
            end if;
            Scan := Skip_Spaces (Text, Scan);
         end if;

         if Scan > Text'Last or else Text (Scan) /= ')' then
            return;
         end if;
         Scan := Scan + 1;

         --  A cut answers with a list, and a template takes one side of it.
         --  Only the two ends are read, because only the two ends are what a
         --  template asks for: what came before the marker, or what came
         --  after the last one.
         if Doing = Method_Split_First then
            if Scan + 2 <= Text'Last and then Text (Scan .. Scan + 2) = "[0]"
            then
               Scan := Scan + 3;
            elsif Scan + 3 <= Text'Last
              and then Text (Scan .. Scan + 3) = "[-1]"
            then
               Doing_Now := Method_Split_Last;
               Scan := Scan + 4;
            else
               return;
            end if;
         end if;

         if Result.Chained >= Max_Methods then
            Result := Refused ("method chain");
            From := Scan;
            Ok := True;
            return;
         end if;

         Result.Chained := Result.Chained + 1;
         Result.Methods (Result.Chained) :=
           (Kind => Doing_Now, At_Operand => Kept);
         From := Scan;
         Ok := True;
      end Add_Method;

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

         --  A number, with a sign where it carries one. The sign is part of
         --  the number and not an operator: a template counting backwards
         --  writes range(n, -1, -1), and reading the minus as subtraction
         --  there would be reading two of the three numbers as one.
         if Text (Index) in '0' .. '9'
           or else (Text (Index) = '-'
                    and then Index < Text'Last
                    and then Text (Index + 1) in '0' .. '9')
         then
            declare
               Start  : constant Natural := Index;
               Stored : Boolean;
            begin
               if Text (Index) = '-' then
                  Index := Index + 1;
               end if;
               while Index <= Text'Last and then Text (Index) in '0' .. '9' loop
                  Index := Index + 1;
               end loop;
               Result.Kind := Term_Literal;
               Result.Numeric := True;
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

               --  Where a method's name begins inside the word, or zero.
               --  Read_Word takes a dotted name whole, so "a.b.strip" comes
               --  back as one word and the method has to be cut off it here
               --  rather than read as a token of its own.
               function Method_At (Suffix : String) return Natural is
               begin
                  if Word'Length > Suffix'Length
                    and then Word (Word'Last - Suffix'Length + 1 .. Word'Last)
                             = Suffix
                  then
                     return Word'Last - Suffix'Length + 1;
                  end if;
                  return 0;
               end Method_At;

               Cut   : Natural := 0;
               Doing : Method_Kind := Method_None;
            begin
               --  What the word ends with, longest first: rstrip and lstrip
               --  both end in strip.
               for Named of Method_Names loop
                  if Cut = 0 then
                     Cut := Method_At (Named.Text.all);
                     if Cut /= 0 then
                        Doing := Named.Kind;
                     end if;
                  end if;
               end loop;

               if Doing /= Method_None then
                  declare
                     Head  : constant String := Word (Word'First .. Cut - 1);
                     Inner : Natural := Head'First;
                     Taken : Boolean;
                  begin
                     if Head'Length = 0 then
                        return;
                     end if;

                     --  What the method is applied to, read as a term of its
                     --  own so that a method on a message's content and a
                     --  method on a name are the same thing said twice.
                     Read_Bare_Term (Head, Inner, Result, Taken);
                     if not Taken
                       or else Skip_Spaces (Head, Inner) <= Head'Last
                     then
                        Result := Refused (Head);
                        Ok := True;
                        return;
                     end if;

                     Add_Method (Text, Doing, From, Result, Ok);
                     return;
                  end;
               end if;

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
                        elsif Field = "'tool_calls'"
                          or else Field = """tool_calls"""
                        then
                           Result.Kind := Term_Message_Calls;
                        else
                           return;
                        end if;
                     end;
                     From := Close_Bracket + 1;
                     Ok := True;
                     return;
                  end;
               end if;

               --  A message named by position: messages[0]['role'],
               --  messages[0].role, and the same with a position the
               --  template works out rather than writes. Templates use it to
               --  ask whether the conversation already opens with a system
               --  message, and to look at the message beside this one.
               if Word /= "message" and then From <= Text'Last
                 and then Text (From) = '['
               then
                  declare
                     Shut  : Natural := From + 1;
                     Level : Natural := 0;
                  begin
                     while Shut <= Text'Last loop
                        if Text (Shut) = '[' then
                           Level := Level + 1;
                        elsif Text (Shut) = ']' then
                           exit when Level = 0;
                           Level := Level - 1;
                        end if;
                        Shut := Shut + 1;
                     end loop;

                     if Shut > Text'Last then
                        return;
                     end if;

                     declare
                        Inside : constant String :=
                          Model_Runner.Text.Trim (Text (From + 1 .. Shut - 1));
                        Where  : Natural := Inside'First;
                        Index  : Operand;
                        Taken  : Boolean;
                        Kept   : Natural;
                        After  : Natural := Shut + 1;
                        Field  : Natural := 0;
                     begin
                        --  A slice means something else and is read where a
                        --  set is compiled, not here.
                        if Inside'Length = 0
                          or else (for some Letter of Inside => Letter = ':')
                        then
                           return;
                        end if;

                        Read_Operand (Inside, Where, Index, Taken);
                        if not Taken
                          or else Skip_Spaces (Inside, Where) <= Inside'Last
                        then
                           return;
                        end if;

                        --  Which field, written either way round: a bracket
                        --  with a quoted name in it, or a dot and the name.
                        if After <= Text'Last and then Text (After) = '[' then
                           declare
                              Ends : Natural := After + 1;
                           begin
                              while Ends <= Text'Last
                                and then Text (Ends) /= ']'
                              loop
                                 Ends := Ends + 1;
                              end loop;
                              if Ends > Text'Last then
                                 return;
                              end if;

                              declare
                                 Named : constant String :=
                                   Model_Runner.Text.Trim
                                     (Text (After + 1 .. Ends - 1));
                              begin
                                 if Named = "'role'"
                                   or else Named = """role"""
                                 then
                                    Field := 1;
                                 elsif Named = "'content'"
                                   or else Named = """content"""
                                 then
                                    Field := 2;
                                 else
                                    return;
                                 end if;
                              end;
                              After := Ends + 1;
                           end;
                        elsif After + 4 <= Text'Last
                          and then Text (After .. After + 4) = ".role"
                        then
                           Field := 1;
                           After := After + 5;
                        elsif After + 7 <= Text'Last
                          and then Text (After .. After + 7) = ".content"
                        then
                           Field := 2;
                           After := After + 8;
                        else
                           return;
                        end if;

                        Keep (Index, Kept);
                        if Kept = 0 then
                           return;
                        end if;

                        Result.Kind :=
                          (if Field = 1 then Term_Indexed_Role
                           else Term_Indexed_Content);

                        --  Which list, so that a template that rebinds the
                        --  name reads the rebound one, and where the index
                        --  was kept.
                        Result.Offset := 0;
                        Result.Index_At := Kept;
                        Result.Length := Slot_Of (Word);
                        if Result.Length = 0 then
                           Result := Refused (Word);
                        end if;
                        From := After;
                        Ok := True;
                        return;
                     end;
                  end;
               end if;

               if Word = "message.role" then
                  Result.Kind := Term_Message_Role;
               elsif Word = "message.content" then
                  Result.Kind := Term_Message_Content;
               elsif Word = "message.tool_calls" then
                  --  Whether this turn asked for tools. It has no text --
                  --  a list of calls is not something to print -- so a
                  --  condition is the only place it answers.
                  Result.Kind := Term_Message_Calls;
               elsif Word = "tool_call.name" then
                  Result.Kind := Term_Call_Name;
               elsif Word = "tool_call.arguments" then
                  Result.Kind := Term_Call_Arguments;
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
                  Result.Numeric := True;
               elsif Word = "loop.index" then
                  Result.Kind := Term_Loop_Index_One;
                  Result.Numeric := True;
               elsif Word = "true" then
                  Result.Kind := Term_True;
               elsif Word = "false" then
                  Result.Kind := Term_False;
               elsif Word = "none" then
                  Result.Kind := Term_None;
               elsif Word = "enable_thinking" then
                  --  The one name a caller may answer that the template
                  --  reads as a name of its own. Recorded so the render
                  --  knows where to put the answer, and made a slot like any
                  --  other so a template that assigns it still works.
                  Result.Kind := Term_Variable;
                  Result.Offset := Slot_Of (Word);
                  if Result.Offset = 0 then
                     Result := Refused (Word);
                  else
                     Item.Thinking_Slot := Result.Offset;
                  end if;

               elsif Is_Plain_Name (Word)
                 or else Is_Namespace_Field (Word)
               then
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

         --  Methods written one after another: a template that cuts a reply
         --  at its reasoning marker and then trims what is left writes four
         --  in a row, and each takes what the one before it answered.
         loop
            declare
               Scan  : constant Natural := Skip_Spaces (Text, From);
               Doing : Method_Kind := Method_None;
               Ends  : Natural := 0;
               Taken : Boolean;
            begin
               exit when Scan > Text'Last or else Text (Scan) /= '.';

               for Named of Method_Names loop
                  if Doing = Method_None
                    and then Scan + Named.Text.all'Length - 1 <= Text'Last
                    and then Text (Scan .. Scan + Named.Text.all'Length - 1)
                             = Named.Text.all
                  then
                     Doing := Named.Kind;
                     Ends := Scan + Named.Text.all'Length;
                  end if;
               end loop;

               exit when Doing = Method_None
                 or else Ends > Text'Last
                 or else Text (Ends) /= '(';

               From := Ends;
               Add_Method (Text, Doing, From, Result, Taken);
               exit when not Taken;
            end;
         end loop;

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
                  Result.Numeric := True;
               elsif Text (First .. Last) = "tojson" then
                  Result.Filter := Filter_JSON;
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
         Value  : Term;
         Taken  : Boolean;
         Joined : Join_Kind := Join_Plus;
      begin
         Result := (others => <>);
         Ok := False;

         loop
            Read_Term (Text, From, Value, Taken);
            exit when not Taken;

            if Result.Count >= Max_Terms then
               return;
            end if;
            Value.Join := Joined;
            Result.Count := Result.Count + 1;
            Result.Terms (Result.Count) := Value;

            declare
               Next : constant Natural := Skip_Spaces (Text, From);
            begin
               exit when Next > Text'Last
                 or else (Text (Next) /= '+' and then Text (Next) /= '-');

               --  Which way the next term joins this one, carried on that
               --  term rather than here: an operand is a list and the join
               --  belongs between two of its entries.
               Joined := (if Text (Next) = '-' then Join_Minus else Join_Plus);
               From := Next + 1;
            end;
         end loop;

         Ok := Result.Count > 0;
      end Read_Operand;

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

      procedure Compile_Set (Text : String) is
         Scan        : Natural := Text'First;
         First, Last : Natural;
         Target      : Natural := 0;
         Where       : Natural;
      begin
         Read_Word (Text, Scan, First, Last);
         if Last >= First
           and then (Is_Plain_Name (Text (First .. Last))
                     or else Is_Namespace_Field (Text (First .. Last)))
         then
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

               --  namespace(a = x, b = y): a holder with named fields, which
               --  becomes one ordinary assignment per field. The name of the
               --  holder is remembered so that ns.a reads as a name later,
               --  and is not confused with message.role, which is spelled
               --  the same way and is not a name.
               if Model_Runner.Text.Starts_With (Rest, "namespace(") then
                  declare
                     Shut : Natural := Rest'Last;
                  begin
                     while Shut >= Rest'First and then Rest (Shut) /= ')' loop
                        Shut := Shut - 1;
                     end loop;

                     if Shut < Rest'First then
                        Refuse (Text, Where);
                        return;
                     end if;

                     Namespaces (Target) := True;

                     declare
                        Fields : constant String :=
                          Rest (Rest'First + 10 .. Shut - 1);
                        Head_Name : constant String := Text (First .. Last);
                        At_Field  : Natural := Fields'First;
                     begin
                        while At_Field <= Fields'Last loop
                           declare
                              Ends : Natural := At_Field;
                              Level : Natural := 0;
                           begin
                              --  One field a comma, and a comma inside
                              --  brackets belongs to what is inside them.
                              while Ends <= Fields'Last loop
                                 if Fields (Ends) = '(' then
                                    Level := Level + 1;
                                 elsif Fields (Ends) = ')' and then Level > 0
                                 then
                                    Level := Level - 1;
                                 elsif Fields (Ends) = ',' and then Level = 0
                                 then
                                    exit;
                                 end if;
                                 Ends := Ends + 1;
                              end loop;

                              Compile_Set
                                (Head_Name & "."
                                 & Model_Runner.Text.Trim
                                     (Fields (At_Field .. Ends - 1)));
                              At_Field := Ends + 1;
                           end;
                        end loop;
                     end;
                     return;
                  end;
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

               --  One message of a list, named by a position the template
               --  works out: messages[index] and its like. What a template
               --  does when it walks the conversation by number rather than
               --  by loop, which is the only way to walk it backwards.
               if Name /= 0 and then Head <= Rest'Last
                 and then Rest (Head) = '['
                 and then Rest (Rest'Last) = ']'
               then
                  declare
                     Inside : constant String :=
                       Model_Runner.Text.Trim
                         (Rest (Head + 1 .. Rest'Last - 1));
                     Where_At : Natural := Inside'First;
                     Index    : Operand;
                     Taken    : Boolean;
                     Kept     : Natural;
                  begin
                     --  A slice is written the same way as far as the
                     --  opening bracket and means something else; it is
                     --  told apart by the colon, and is handled below.
                     if Inside'Length > 0
                       and then (for all Letter of Inside => Letter /= ':')
                     then
                        Read_Operand (Inside, Where_At, Index, Taken);
                        if Taken
                          and then Skip_Spaces (Inside, Where_At)
                                   > Inside'Last
                        then
                           Keep (Index, Kept);
                           if Kept = 0 then
                              return;
                           end if;
                           Emit ((Op => Op_Set_Message, Offset => Target,
                                  Target => Name, Value_At => Kept,
                                  others => <>), Where);
                           return;
                        end if;
                     end if;
                  end;
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

               --  Whether this loop counts rather than walks a list, and
               --  where the three numbers it counts by were kept.
               Counting  : Boolean := False;
               Counted   : Boolean := False;
               Bounds_At : Natural := 0;

               --  Whether it walks the tools instead, or the calls one
               --  turn asked for, and whether it stands inside a loop that
               --  already walks one of those.
               Walking      : Boolean := False;
               Calling      : Boolean := False;
               Inside_Tools : constant Boolean :=
                 (for some Level in 1 .. Depth =>
                    Frames (Level).Walks_Tools
                    or else Frames (Level).Walks_Calls);
            begin
               --  Four loops, told apart by what is looped over. Over a
               --  list the variable is always named message, because the
               --  fields this engine can read from an iterate are a
               --  message's fields; over a range of whole numbers the
               --  variable holds a number and may be named anything; over
               --  the tools a caller offered it holds one tool, which has no
               --  text and is written with tojson; over the calls one turn
               --  asked for it is always named tool_call, for the reason
               --  the list loop's variable is always named message. Any
               --  other loop is compiled but refuses if reached.
               Counting := False;
               Read_Word (Rest, Scan, First, Last);
               if Last >= First and then Is_Plain_Name (Rest (First .. Last))
               then
                  declare
                     Named : constant String := Rest (First .. Last);
                  begin
                     Read_Word (Rest, Scan, First, Last);
                     if Last >= First and then Rest (First .. Last) = "in" then
                        declare
                           Tail : constant String :=
                             Model_Runner.Text.Trim
                               (Rest (Scan .. Rest'Last));
                        begin
                           if Model_Runner.Text.Starts_With (Tail, "range(")
                             and then Tail (Tail'Last) = ')'
                           then
                              Counting := True;
                              Read_Range
                                (Tail (Tail'First + 6 .. Tail'Last - 1),
                                 Bounds_At, Counted);
                              Over := (if Counted then Slot_Of (Named) else 0);
                           elsif Tail = "tools" then
                              --  The tools themselves, whatever the loop
                              --  calls each of them. Asked for by name
                              --  rather than by what the slot holds,
                              --  because what it holds is known when the
                              --  render runs and this is decided now.
                              Walking := Slot_Of (Tail) /= 0;
                              Over := (if Walking then Slot_Of (Named) else 0);
                           elsif Named = "tool_call"
                             and then (Tail = "message.tool_calls"
                                       or else Tail = "message['tool_calls']")
                           then
                              --  The calls the bound turn asked for. Which
                              --  turn that is is known when the render
                              --  runs; that it is the bound one is decided
                              --  here.
                              Calling := True;
                              Over := Slot_Of (Named);
                           elsif Named = "message"
                             and then Is_Plain_Name (Tail)
                           then
                              Over := Slot_Of (Tail);
                           end if;

                           --  A loop inside a loop over tools cannot say
                           --  which loop its loop.first is about, and there
                           --  is one place for a tools loop to keep where
                           --  it has got to. Refused where it is used
                           --  rather than compiled into an answer that is
                           --  right for one of the two loops.
                           if Inside_Tools then
                              Over := 0;
                           end if;
                        end;
                     end if;
                  end;
               end if;

               if Depth >= Max_Depth then
                  Fail (E.Template_Nesting_Too_Deep, "for");
                  return;
               end if;

               if Over = 0 then
                  Refuse (Rest, Where);
               elsif Counting then
                  Emit ((Op => Op_Range_Begin, Offset => Over,
                         Value_At => Bounds_At, others => <>), Where);
               elsif Walking then
                  Emit ((Op => Op_Tool_Begin, Offset => Over, others => <>),
                        Where);
               elsif Calling then
                  Emit ((Op => Op_Call_Begin, Offset => Over, others => <>),
                        Where);
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
                  Numeric => Counting and then Over /= 0,
                  Walks_Tools => Walking and then Over /= 0,
                  Walks_Calls => Calling and then Over /= 0, others => <>);
               Exit_Chain (Depth) := 0;
            end;

         elsif Trimmed = "endfor" then
            if Depth = 0 or else Frames (Depth).Kind /= Block_For then
               Fail (E.Template_Unbalanced_Block, "endfor");
               return;
            end if;

            if not Frames (Depth).Dead then
               Emit ((Op => (if Frames (Depth).Numeric then Op_Range_Next
                             elsif Frames (Depth).Walks_Tools then Op_Tool_Next
                             elsif Frames (Depth).Walks_Calls then Op_Call_Next
                             else Op_For_Next),
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

      --  And the name a message goes by, made now rather than when a
      --  template happens to mention it, so that message.role has one slot
      --  to read whether the binding came from a loop or an assignment.
      Item.Message_Slot := Slot_Of ("message");
      if Item.Message_Slot = 0 then
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
      Status                : out E.Error_Info;
      Thinking              : Thinking_Choice := Thinking_Unstated;
      Tools                 : access constant Offered_Tools.Definitions
        := null)
   is
      Count      : constant Natural := Conv.Length (Messages);

      --  How many tools the caller offered. None and none offered are the
      --  same thing to a template: "if tools" is false either way, and a
      --  model told about no tools is a model that was told nothing.
      Tool_Count : constant Natural :=
        (if Tools = null then 0 else Offered_Tools.Count (Tools.all));
      Position   : Natural := 1;
      Current    : Natural := 0;
      Loop_Start : Positive := 1;
      Iterations : Natural := 0;
      Overflow   : Boolean := False;

      --  What a name holds. A list is held as the position it starts at,
      --  because the only thing a template does to one is drop entries from
      --  the front of it.
      type Value_Kind is
        (Value_Undefined, Value_Text, Value_None, Value_List,

         --  One message of a list, held as its position. What a template
         --  binds when it walks the conversation by index rather than by
         --  loop, and what a loop binds too.
         Value_Message,

         --  The tools the caller offered, and one of them. Neither has any
         --  text: a template asks whether there are tools, walks them, and
         --  writes each one with tojson, and anything else it might do with
         --  one is refused rather than answered with a spelling this engine
         --  chose.
         Value_Tools,
         Value_JSON,

         --  One call of one turn, held as both positions: which message
         --  asked for it, and which of that message's calls it is. Both,
         --  because the loop that binds it runs inside the loop that binds
         --  the message and the inner binding must not depend on the outer
         --  one still being where it was.
         Value_Call);

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

      --  Give a name a text value, taking back the room the name last held
      --  where that room is the newest in the pool. Written once because
      --  three instructions do it and one of them does it every time round
      --  a loop.
      procedure Assign_Text (Where : Natural; Value : String) is
         Held : Slot renames Slots (Where);
      begin
         --  A name reassigned in a loop -- which is how a template builds
         --  one message's text before emitting it -- is almost always the
         --  newest thing in the pool. Taking its room back makes that loop
         --  cost what one iteration costs instead of what all of them do.
         --  Value is already a copy, so the old text may go.
         if Held.Kind = Value_Text
           and then Held.Offset + Held.Length = Pool_Used
         then
            Pool_Used := Held.Offset;
         end if;

         if Pool_Used + Value'Length > Pool'Length then
            Refuse (Item.Names (Where).Offset, Item.Names (Where).Length,
                    E.Template_Variables_Too_Large);
         else
            Pool (Pool_Used + 1 .. Pool_Used + Value'Length) := Value;
            Slots (Where) :=
              (Kind => Value_Text, Offset => Pool_Used,
               Length => Value'Length, Start => 1);
            Pool_Used := Pool_Used + Value'Length;
         end if;
      end Assign_Text;

      --  Bind the name a message goes by to one position, or to nothing.
      --  A loop binds it as it goes, which is what makes message.role inside
      --  a loop and message.role after an assignment the same question.
      procedure Bind_Message (At_Message : Natural) is
      begin
         if Item.Message_Slot = 0 then
            return;
         elsif At_Message = 0 then
            Slots (Item.Message_Slot) := (Kind => Value_Undefined,
                                          others => <>);
         else
            Slots (Item.Message_Slot) :=
              (Kind => Value_Message, Offset => 0, Length => 0,
               Start => At_Message);
         end if;
      end Bind_Message;

      --  Which message the name message stands for. A loop binds it, and
      --  so does an assignment; the binding in force is whatever the name
      --  holds, and the loop's own position is what it holds while a loop
      --  is running.
      function Bound_Message return Natural is
         Held : Slot renames Slots (Item.Message_Slot);
      begin
         return (if Held.Kind = Value_Message then Held.Start else Current);
      end Bound_Message;

      --  Where a loop over the calls one turn asked for has got to, which
      --  turn that is, and whether such a loop is running. One set of
      --  these, because a call loop inside a call loop is refused where it
      --  is compiled.
      Call_At      : Natural := 0;
      Call_Message : Natural := 0;
      In_Calls     : Boolean := False;

      --  How many calls the bound turn asked for.
      function Asked_Count return Natural is
         Where : constant Natural := Bound_Message;
      begin
         return (if Where = 0 or else Where > Count then 0
                 else Conv.Call_Count (Messages, Where));
      end Asked_Count;

      --  And how many the running loop is walking, which is the turn it
      --  began on rather than whatever the name message holds now: a
      --  template that rebinds that name inside the loop must not change
      --  what loop.last answers about it.
      function Walking_Count return Natural
      is (if Call_Message = 0 or else Call_Message > Count then 0
          else Conv.Call_Count (Messages, Call_Message));

      --  Where a loop over the tools has got to, and whether one is
      --  running. One set of these, because a tools loop inside a tools
      --  loop is refused where it is compiled; the flag is what makes
      --  loop.first inside such a loop about the tools rather than about
      --  the conversation.
      Tool_At  : Natural := 0;
      In_Tools : Boolean := False;

      --  Where a counting loop has got to, where it stops and what it steps
      --  by, and which name it writes each number to.
      --
      --  One set of these rather than one a depth: a counting loop inside
      --  another counting loop is refused where it is compiled, so there is
      --  never more than one running.
      Range_At   : Long_Long_Integer := 0;
      Range_Stop : Long_Long_Integer := 0;
      Range_Step : Long_Long_Integer := 1;
      Range_Slot : Natural := 0;

      --  Whether the count has passed its stop, which depends on which way
      --  it is going.
      function Counting_On return Boolean
      is (if Range_Step > 0 then Range_At < Range_Stop
          else Range_At > Range_Stop);

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

      --  Declared before Raw_Of because an indexed term's position is an
      --  expression, and reading one needs both of these.
      function Value_Of (Value : Operand) return String;
      function Number_Of (Text : String) return Long_Long_Integer;

      --  Whether what is being evaluated is a condition rather than output.
      --  A condition may ask about a name the template never assigned; the
      --  output may not, and the difference is which of the two is running.
      Testing : Boolean := False;

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
            when Term_Message_Role | Term_Message_Content =>
               declare
                  At_Message : constant Natural := Bound_Message;
               begin
                  if At_Message = 0 or else At_Message > Count then
                     return "";
                  elsif Value.Kind = Term_Message_Role then
                     return Conv.Role_Name
                       (Conv.Sender_At (Messages, At_Message));
                  else
                     return Conv.Content_At (Messages, At_Message);
                  end if;
               end;

            when Term_Message_Calls =>
               --  A list of calls has no text. Asked about in a condition
               --  the answer is whether the turn asked for any, which is
               --  what "if message.tool_calls" is written to find out;
               --  asked for as text it is a template printing a list, and
               --  there is no spelling of one this engine may choose.
               if Testing then
                  return (if Asked_Count > 0 then "true" else "");
               end if;

               Refuse (Value.Offset, Value.Length,
                       E.Template_Unsupported_Construct);
               return "";

            when Term_Call_Name | Term_Call_Arguments =>
               --  Which call the name tool_call stands for, and which turn
               --  it belongs to. Both come from the binding where there is
               --  one, and from the running loop otherwise, for the reason
               --  a message's fields do. A field asked for where no call is
               --  bound is empty rather than an error, which is the answer
               --  a message's fields give outside a loop.
               declare
                  At_Message : Natural := Call_Message;
                  At_Call    : Natural := Call_At;
               begin
                  if Item.Call_Slot /= 0
                    and then Slots (Item.Call_Slot).Kind = Value_Call
                  then
                     At_Message := Slots (Item.Call_Slot).Offset;
                     At_Call := Slots (Item.Call_Slot).Start;
                  end if;

                  if At_Message = 0 or else At_Call = 0
                    or else At_Message > Count
                  then
                     return "";
                  elsif Value.Kind = Term_Call_Name then
                     return Conv.Call_Name (Messages, At_Message, At_Call);
                  else
                     return Conv.Call_Arguments
                       (Messages, At_Message, At_Call);
                  end if;
               end;
            when Term_Indexed_Role | Term_Indexed_Content =>
               --  Counted from zero in the template and from one here, and
               --  from wherever the list it names begins, which a template
               --  moves when it lifts the system message out. A position the
               --  conversation does not reach is empty rather than an error,
               --  which is what a template comparing it against a role name
               --  expects.
               declare
                  Holder : Slot renames Slots (Value.Length);
                  Wanted : constant Long_Long_Integer :=
                    (if Value.Index_At = 0
                     then Long_Long_Integer (Value.Offset)
                     else Number_Of
                            (Value_Of (Item.Operands.all (Value.Index_At))));
                  At_Message : constant Long_Long_Integer :=
                    Long_Long_Integer (Holder.Start) + Wanted;
               begin
                  if Holder.Kind /= Value_List then
                     Refuse (0, 0, E.Template_Unsupported_Construct);
                     return "";
                  elsif At_Message < 1
                    or else At_Message > Long_Long_Integer (Count)
                  then
                     return "";
                  elsif Value.Kind = Term_Indexed_Role then
                     return Conv.Role_Name
                       (Conv.Sender_At (Messages, Natural (At_Message)));
                  else
                     return Conv.Content_At
                       (Messages, Natural (At_Message));
                  end if;
               end;
            when Term_Generation_Prompt =>
               return (if Add_Generation_Prompt then "true" else "");
            when Term_Loop_First =>
               if In_Calls then
                  return (if Call_At = 1 then "true" else "");
               elsif In_Tools then
                  return (if Tool_At = 1 then "true" else "");
               end if;
               return (if Current = Loop_Start then "true" else "");
            when Term_Loop_Last =>
               if In_Calls then
                  return (if Call_At = Walking_Count then "true" else "");
               elsif In_Tools then
                  return (if Tool_At = Tool_Count then "true" else "");
               end if;
               return (if Current = Count and then Count > 0 then "true" else "");
            when Term_Loop_Index_Zero =>
               if In_Calls then
                  return Model_Runner.Text.Image
                    (Long_Long_Integer (Call_At) - 1);
               elsif In_Tools then
                  return Model_Runner.Text.Image
                    (Long_Long_Integer (Tool_At) - 1);
               end if;
               return Model_Runner.Text.Image
                 (Long_Long_Integer (Current) - Long_Long_Integer (Loop_Start));
            when Term_Loop_Index_One =>
               if In_Calls then
                  return Model_Runner.Text.Image (Long_Long_Integer (Call_At));
               elsif In_Tools then
                  return Model_Runner.Text.Image (Long_Long_Integer (Tool_At));
               end if;
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
                        --  A name never assigned is nothing. Asked about in
                        --  a condition that is the answer -- a template
                        --  writes "if tools" precisely to find out whether
                        --  it was given any -- and asked for in output it is
                        --  a template reading something it never wrote,
                        --  which would put the empty string where it meant
                        --  text and say nothing about it.
                        if not Testing then
                           Refuse (Name.Offset, Name.Length,
                                   E.Template_Unknown_Variable);
                        end if;
                        return "";
                     when Value_Tools | Value_JSON =>
                        --  The tools, or one of them. Asked about in a
                        --  condition the answer is that there is something
                        --  there -- "if tools" is written to find out
                        --  whether the caller offered any -- and asked for
                        --  as text it is a template printing an object,
                        --  which has no spelling this engine may choose.
                        --  Written with tojson it never reaches here.
                        if Testing then
                           return "true";
                        end if;

                        Refuse (Name.Offset, Name.Length,
                                E.Template_Unsupported_Construct);
                        return "";

                     when Value_List | Value_Message | Value_Call =>
                        --  A list, a message and a call have no text. Asking
                        --  one for its text is a template doing something
                        --  this engine does not model, not a template asking
                        --  for the empty string.
                        Refuse (Name.Offset, Name.Length,
                                E.Template_Unsupported_Construct);
                        return "";
                  end case;
               end;
            when Term_Unsupported =>
               --  A name this engine has never heard of is nothing when a
               --  condition asks about it -- a template writes "if
               --  message.tool_calls" to find out whether there are any --
               --  and a refusal when the output asks for it. A construct it
               --  cannot evaluate refuses either way: there is no answer to
               --  give, and a condition guessed at is a branch taken for no
               --  reason.
               if Testing and then Value.Why = E.Template_Unknown_Variable
               then
                  return "";
               end if;

               Refuse (Value.Offset, Value.Length, Value.Why);
               return "";
         end case;
      end Raw_Of;

      --  What one method does to the text it is written after.
      function Applied (Step : Method_Step; Held : String) return String is
         --  The characters it takes off, or the marker it cuts at. An
         --  absent argument means whitespace, which is what the language
         --  means by strip with nothing in its brackets.
         Argument : constant String :=
           (if Step.At_Operand = 0 then " " & ASCII.HT & ASCII.LF & ASCII.CR
            else Value_Of (Item.Operands.all (Step.At_Operand)));

         function Is_Trimmed (Letter : Character) return Boolean
         is (for some Wanted of Argument => Wanted = Letter);

         First : Natural := Held'First;
         Last  : Natural := Held'Last;
      begin
         case Step.Kind is
            when Method_None =>
               return Held;

            when Method_Strip | Method_Left_Strip | Method_Right_Strip =>
               if Step.Kind /= Method_Right_Strip then
                  while First <= Last and then Is_Trimmed (Held (First)) loop
                     First := First + 1;
                  end loop;
               end if;
               if Step.Kind /= Method_Left_Strip then
                  while Last >= First and then Is_Trimmed (Held (Last)) loop
                     Last := Last - 1;
                  end loop;
               end if;
               return Held (First .. Last);

            when Method_Split_First | Method_Split_Last =>
               --  The text before the first marker, or after the last one.
               --  A text with no marker in it is one piece, and both ends of
               --  one piece are the piece.
               if Argument'Length = 0 or else Held'Length < Argument'Length
               then
                  return Held;
               end if;

               if Step.Kind = Method_Split_First then
                  for Start in Held'First .. Held'Last - Argument'Length + 1
                  loop
                     if Held (Start .. Start + Argument'Length - 1) = Argument
                     then
                        return Held (Held'First .. Start - 1);
                     end if;
                  end loop;
               else
                  for Start in reverse
                    Held'First .. Held'Last - Argument'Length + 1
                  loop
                     if Held (Start .. Start + Argument'Length - 1) = Argument
                     then
                        return Held (Start + Argument'Length .. Held'Last);
                     end if;
                  end loop;
               end if;
               return Held;
         end case;
      end Applied;

      --  Every method a term carries, in the order they were written.
      function Chain_Of (Value : Term; Held : String) return String is
      begin
         if Value.Chained = 0 then
            return Held;
         elsif Value.Chained = 1 then
            return Applied (Value.Methods (1), Held);
         end if;

         --  Written out rather than looped, because each step's answer is a
         --  slice of the one before it and a loop would need a copy at every
         --  step. Four is the chain this engine takes.
         declare
            One : constant String := Applied (Value.Methods (1), Held);
         begin
            if Value.Chained = 2 then
               return Applied (Value.Methods (2), One);
            end if;
            declare
               Two : constant String := Applied (Value.Methods (2), One);
            begin
               if Value.Chained = 3 then
                  return Applied (Value.Methods (3), Two);
               end if;
               declare
                  Three : constant String :=
                    Applied (Value.Methods (3), Two);
               begin
                  return Applied (Value.Methods (4), Three);
               end;
            end;
         end;
      end Chain_Of;

      --  Text as a JSON string: the quotes, the escapes JSON requires and
      --  nothing else. Measured before it is written, so that a long value
      --  costs the room it needs rather than the room the worst case would.
      function Quoted (Value : String) return String is
         Digits_16 : constant String := "0123456789abcdef";

         --  The control characters JSON writes with a letter are named
         --  outright; the rest of them go out as a number, and the ranges
         --  say which are which without either overlapping the other.
         function Room_For (Letter : Character) return Natural
         is (case Letter is
               when '"' | '\' | ASCII.LF | ASCII.CR | ASCII.HT
                  | ASCII.BS | ASCII.FF => 2,
               when Character'Val (0) .. Character'Val (7)
                  | Character'Val (11)
                  | Character'Val (14) .. Character'Val (31) => 6,
               when others => 1);

         Needed : Natural := 2;
         Filled : Natural := 0;
      begin
         for Letter of Value loop
            Needed := Needed + Room_For (Letter);
         end loop;

         declare
            Room : String (1 .. Needed);

            procedure Put_Text (Piece : String) is
            begin
               Room (Filled + 1 .. Filled + Piece'Length) := Piece;
               Filled := Filled + Piece'Length;
            end Put_Text;
         begin
            Put_Text ("""");
            for Letter of Value loop
               case Letter is
                  when '"'      => Put_Text ("\""");
                  when '\'      => Put_Text ("\\");
                  when ASCII.LF => Put_Text ("\n");
                  when ASCII.CR => Put_Text ("\r");
                  when ASCII.HT => Put_Text ("\t");
                  when ASCII.BS => Put_Text ("\b");
                  when ASCII.FF => Put_Text ("\f");
                  when Character'Val (0) .. Character'Val (7)
                     | Character'Val (11)
                     | Character'Val (14) .. Character'Val (31) =>
                     Put_Text
                       ("\u00"
                        & Digits_16
                            (Digits_16'First + Character'Pos (Letter) / 16)
                        & Digits_16
                            (Digits_16'First + Character'Pos (Letter) mod 16));
                  when others =>
                     Put_Text ([1 => Letter]);
               end case;
            end loop;
            Put_Text ("""");
            return Room (1 .. Filled);
         end;
      end Quoted;

      --  What tojson makes of a term. A tool is written as the definitions
      --  hold it, which is the spelling the implementation these templates
      --  were written for produces; text is written as a JSON string; and
      --  anything else is a value this engine has no JSON for, which is a
      --  refusal rather than a guess.
      function JSON_Of (Value : Term) return String is
      begin
         if Value.Kind = Term_Variable then
            declare
               Holder : Slot renames Slots (Value.Offset);
               Name   : Variable_Name renames Item.Names (Value.Offset);
            begin
               case Holder.Kind is
                  when Value_JSON =>
                     return Offered_Tools.Definition (Tools.all, Holder.Start);

                  when Value_Text =>
                     return Quoted
                       (Pool (Holder.Offset + 1
                              .. Holder.Offset + Holder.Length));

                  when Value_None =>
                     return "null";

                  when others =>
                     Refuse (Name.Offset, Name.Length,
                             E.Template_Unsupported_Construct);
                     return "";
               end case;
            end;
         elsif Value.Kind = Term_Literal then
            return Quoted (Raw_Of (Value));
         end if;

         Refuse (Value.Offset, Value.Length,
                 E.Template_Unsupported_Construct);
         return "";
      end JSON_Of;

      --  Value of one term with its filter applied.
      function Value_Of (Value : Term) return String is
      begin
         if Value.Chained > 0 then
            return Chain_Of (Value, Raw_Of (Value));
         end if;

         case Value.Filter is
            when Filter_None =>
               return Raw_Of (Value);

            when Filter_Trim =>
               return Model_Runner.Text.Trim (Raw_Of (Value));

            when Filter_JSON =>
               return JSON_Of (Value);

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
               elsif Value.Kind = Term_Variable
                 and then Slots (Value.Offset).Kind = Value_Tools
               then
                  return Model_Runner.Text.Image
                    (Long_Long_Integer (Tool_Count));
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
      --  A term's value read as a whole number, or zero where it is not
      --  one. Zero rather than an error, because a template comparing a name
      --  it never assigned is asking about nothing, and answering that with
      --  a refusal would refuse a branch nobody takes.
      function Number_Of (Text : String) return Long_Long_Integer is
         Result : Long_Long_Integer := 0;
         Signed : Boolean := False;
         Index  : Natural := Text'First;
      begin
         while Index <= Text'Last and then Text (Index) = ' ' loop
            Index := Index + 1;
         end loop;

         if Index <= Text'Last and then Text (Index) = '-' then
            Signed := True;
            Index := Index + 1;
         end if;

         if Index > Text'Last or else Text (Index) not in '0' .. '9' then
            return 0;
         end if;

         while Index <= Text'Last and then Text (Index) in '0' .. '9' loop
            Result := Result * 10
              + Long_Long_Integer (Character'Pos (Text (Index))
                                   - Character'Pos ('0'));
            Index := Index + 1;
         end loop;

         return (if Signed then -Result else Result);
      end Number_Of;

      function Value_Of (Value : Operand) return String is
         --  Only the filled prefix is ever returned, but defining the whole
         --  buffer costs a kilobyte on a path that is not hot and removes the
         --  question of whether that is really true.
         Result : String (1 .. Max_Comparison) := [others => ' '];
         Filled : Natural := 0;

         --  Whether this operand is a sum rather than a run of text. A
         --  subtraction is one outright: nothing else is written with a
         --  minus. A plus is one when every term of it is a number by
         --  construction -- a bare number, a loop counter, a length -- which
         --  is the language's own rule read off what the terms are rather
         --  than off what they happen to hold. Two pieces of text joined
         --  with a plus are still run together, and two numbers added: a
         --  template asking for messages[loop.index0 + 1] means the message
         --  after this one and not the one at position "01".
         Arithmetic : Boolean := False;
      begin
         for Index in 2 .. Value.Count loop
            Arithmetic :=
              Arithmetic or else Value.Terms (Index).Join = Join_Minus;
         end loop;

         if not Arithmetic and then Value.Count > 1 then
            Arithmetic :=
              (for all Index in 1 .. Value.Count =>
                 Value.Terms (Index).Numeric);
         end if;

         --  A sum is evaluated rather than run together, and its answer is
         --  the number's own text: everything downstream of an operand takes
         --  text, and a number written down is still a number.
         if Arithmetic then
            declare
               Total : Long_Long_Integer :=
                 (if Value.Count = 0 then 0
                  else Number_Of (Value_Of (Value.Terms (1))));
            begin
               for Index in 2 .. Value.Count loop
                  declare
                     Next : constant Long_Long_Integer :=
                       Number_Of (Value_Of (Value.Terms (Index)));
                  begin
                     if Value.Terms (Index).Join = Join_Minus then
                        Total := Total - Next;
                     else
                        Total := Total + Next;
                     end if;
                  end;
               end loop;
               return Model_Runner.Text.Image (Total);
            end;
         end if;

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
               --  Truth of a bare operand, as the language it is written in
               --  means it: the empty string is false, and so are the two
               --  words a template writes for false and for nothing. A flag
               --  a template sets to false is read back as its own text, and
               --  text that says "false" being true would make every such
               --  flag true for ever.
               declare
                  Held : constant String := Value_Of (Value.Left);
               begin
                  Result := Held /= "" and then Held /= "false"
                    and then Held /= "none" and then Held /= "0";
               end;

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

            when Compare_In_Text | Compare_Not_In_Text =>
               --  Whether the left side occurs anywhere in the right. The
               --  same word as the test above and a different question, told
               --  apart by what follows it.
               declare
                  Needle : constant String := Value_Of (Value.Left);
                  Held   : constant String := Value_Of (Value.Right);
                  Found  : Boolean := False;
               begin
                  if Needle'Length > 0
                    and then Held'Length >= Needle'Length
                  then
                     for Start in
                       Held'First .. Held'Last - Needle'Length + 1
                     loop
                        if Held (Start .. Start + Needle'Length - 1) = Needle
                        then
                           Found := True;
                           exit;
                        end if;
                     end loop;
                  end if;
                  Result :=
                    (if Value.Operator = Compare_In_Text
                     then Found else not Found);
               end;

            when Compare_Less | Compare_Less_Or_Equal
               | Compare_Greater | Compare_Greater_Or_Equal =>
               declare
                  Left  : constant Long_Long_Integer :=
                    Number_Of (Value_Of (Value.Left));
                  Right : constant Long_Long_Integer :=
                    Number_Of (Value_Of (Value.Right));
               begin
                  Result :=
                    (case Value.Operator is
                        when Compare_Less             => Left < Right,
                        when Compare_Less_Or_Equal    => Left <= Right,
                        when Compare_Greater          => Left > Right,
                        when others                   => Left >= Right);
               end;

            when Compare_Is_True | Compare_Is_Not_True
               | Compare_Is_False | Compare_Is_Not_False =>
               declare
                  Held : constant String := Value_Of (Value.Left);
                  Says : constant Boolean := Held = "true";
                  Nays : constant Boolean := Held = "false";
               begin
                  Result :=
                    (case Value.Operator is
                        when Compare_Is_True      => Says,
                        when Compare_Is_Not_True  => not Says,
                        when Compare_Is_False     => Nays,
                        when others               => not Nays);
               end;

            when Compare_Is_String | Compare_Is_Not_String =>
               --  Everything this engine holds is text, so the answer is
               --  whether the name holds anything at all. A template asks
               --  this to tell a value it can print from one it must encode,
               --  and here there is nothing it cannot print.
               declare
                  Held : constant Boolean :=
                    Is_Defined (Value.Left)
                    and then not Is_None (Value.Left);
               begin
                  Result :=
                    (if Value.Operator = Compare_Is_String
                     then Held else not Held);
               end;

            when Compare_In_Message =>
               --  The fields a message has here. Two it always has, and one
               --  it has when it asked for it: a turn that called nothing
               --  does not carry tool_calls, which is the same answer the
               --  implementation these templates were written for gives and
               --  the reason the question is asked at all. Any other field
               --  is one this engine cannot hold, and the honest answer is
               --  that this message does not have it.
               declare
                  Field : constant String := Value_Of (Value.Left);
               begin
                  Result := Field = "role" or else Field = "content"
                    or else (Field = "tool_calls" and then Asked_Count > 0);
               end;
         end case;

         return (if Value.Negated then not Result else Result);
      end Truth_Of;

      --  Truth of a whole condition: any conjunction being true is enough.
      function Truth_Of (Value : Condition) return Boolean is
         --  Restored rather than cleared: a condition inside a condition --
         --  a parenthesised group -- must leave the outer one still testing.
         Was     : constant Boolean := Testing;
         Answer  : Boolean := False;
      begin
         Testing := True;
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
                  Answer := True;
                  exit;
               end if;
            end;
         end loop;
         Testing := Was;
         return Answer;
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

      --  And the tools, where the template reads them and the caller
      --  offered some. Left undefined otherwise, which is what makes
      --  "if tools" false for a caller who offered none -- the same answer a
      --  template gets from a build that had never heard of them.
      if Item.Tools_Slot /= 0 and then Tool_Count > 0 then
         Slots (Item.Tools_Slot) := (Kind => Value_Tools, others => <>);
      end if;

      --  And the name a reasoning model's template asks after, where it asks
      --  and where the caller has an answer. Left undefined otherwise, which
      --  is what the template's own "is defined" is there to find out: a
      --  caller who says nothing leaves the model to do what it was trained
      --  to do.
      if Item.Thinking_Slot /= 0 and then Thinking /= Thinking_Unstated then
         Assign_Text
           (Item.Thinking_Slot,
            (if Thinking = Thinking_On then "true" else "false"));
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
                        Bind_Message (Current);
                        Position := Position + 1;
                     end if;
                  end;

               when Op_For_Next =>
                  if Current < Count then
                     Current := Current + 1;
                     Bind_Message (Current);
                     Position := Step.Target + 1;
                  else
                     Current := 0;
                     Bind_Message (0);
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
                  Assign_Text
                    (Step.Offset,
                     Value_Of (Item.Operands.all (Step.Value_At)));
                  Position := Position + 1;

               when Op_Set_Message =>
                  --  Counted from zero in the template and from one here,
                  --  and from wherever the list it names begins. A position
                  --  the conversation does not reach binds nothing, which is
                  --  what a template comparing its role against a name
                  --  expects rather than an error.
                  declare
                     From_List : Slot renames Slots (Step.Target);
                     Wanted : constant Long_Long_Integer :=
                       Number_Of (Value_Of (Item.Operands.all (Step.Value_At)));
                     At_Message : constant Long_Long_Integer :=
                       Long_Long_Integer (From_List.Start) + Wanted;
                  begin
                     if From_List.Kind /= Value_List then
                        Refuse (Item.Names (Step.Target).Offset,
                                Item.Names (Step.Target).Length,
                                E.Template_Unsupported_Construct);
                     elsif At_Message >= 1
                       and then At_Message <= Long_Long_Integer (Count)
                     then
                        Slots (Step.Offset) :=
                          (Kind => Value_Message, Offset => 0, Length => 0,
                           Start => Positive (At_Message));
                     else
                        Slots (Step.Offset) := (Kind => Value_None,
                                                others => <>);
                     end if;
                  end;
                  Position := Position + 1;

               when Op_Tool_Begin =>
                  --  A caller who offered nothing skips the loop rather
                  --  than running it none times, which is the same thing
                  --  said in one instruction instead of two.
                  if Tool_Count = 0 then
                     Position := Step.Target;
                  else
                     Tool_At := 1;
                     In_Tools := True;
                     Slots (Step.Offset) :=
                       (Kind => Value_JSON, Start => 1, others => <>);
                     Position := Position + 1;
                  end if;

               when Op_Tool_Next =>
                  --  Which name the loop writes to is kept in the
                  --  instruction that began it, which is where this jumps
                  --  back to anyway.
                  declare
                     Named : constant Natural :=
                       Item.Program.all (Step.Target).Offset;
                  begin
                     if Tool_At < Tool_Count then
                        Tool_At := Tool_At + 1;
                        Slots (Named) :=
                          (Kind => Value_JSON, Start => Tool_At,
                           others => <>);
                        Position := Step.Target + 1;
                     else
                        Tool_At := 0;
                        In_Tools := False;
                        Slots (Named) := (Kind => Value_Undefined,
                                          others => <>);
                        Position := Position + 1;
                     end if;
                  end;

               when Op_Call_Begin =>
                  --  A turn that asked for nothing skips the loop rather
                  --  than running it none times, which is what the tools
                  --  loop does with a caller who offered none.
                  declare
                     Asked : constant Natural := Asked_Count;
                  begin
                     if Asked = 0 then
                        Position := Step.Target;
                     else
                        Call_Message := Bound_Message;
                        Call_At := 1;
                        In_Calls := True;
                        Slots (Step.Offset) :=
                          (Kind => Value_Call, Offset => Call_Message,
                           Length => 0, Start => 1);
                        Position := Position + 1;
                     end if;
                  end;

               when Op_Call_Next =>
                  --  Which name the loop writes to is kept in the
                  --  instruction that began it, which is where this jumps
                  --  back to anyway.
                  declare
                     Named : constant Natural :=
                       Item.Program.all (Step.Target).Offset;
                     Asked : constant Natural := Walking_Count;
                  begin
                     if Call_At < Asked then
                        Call_At := Call_At + 1;
                        Slots (Named) :=
                          (Kind => Value_Call, Offset => Call_Message,
                           Length => 0, Start => Call_At);
                        Position := Step.Target + 1;
                     else
                        Call_At := 0;
                        Call_Message := 0;
                        In_Calls := False;
                        Slots (Named) := (Kind => Value_Undefined,
                                          others => <>);
                        Position := Position + 1;
                     end if;
                  end;

               when Op_Range_Begin =>
                  --  The three numbers are read once, where the loop begins.
                  --  A template that counted from something it changes inside
                  --  the loop would be a template whose end nobody can see,
                  --  and this counts to where it was told to at the start.
                  declare
                     Bounds : Natural renames Step.Value_At;
                  begin
                     Range_Slot := Step.Offset;
                     Range_At :=
                       Number_Of (Value_Of (Item.Operands.all (Bounds)));
                     Range_Stop :=
                       Number_Of (Value_Of (Item.Operands.all (Bounds + 1)));
                     Range_Step :=
                       Number_Of (Value_Of (Item.Operands.all (Bounds + 2)));

                     if Range_Step = 0 or else not Counting_On then
                        Position := Step.Target;
                     else
                        Assign_Text
                          (Range_Slot, Model_Runner.Text.Image (Range_At));
                        Position := Position + 1;
                     end if;
                  end;

               when Op_Range_Next =>
                  Range_At := Range_At + Range_Step;
                  if Counting_On then
                     Assign_Text
                       (Range_Slot, Model_Runner.Text.Image (Range_At));
                     Position := Step.Target + 1;
                  else
                     Position := Position + 1;
                  end if;

               when Op_Set_None =>
                  Slots (Step.Offset) := (Kind => Value_None, others => <>);
                  Position := Position + 1;

               when Op_Set_Copy =>
                  --  Text is copied, and everything else is the same value
                  --  named twice. A copied slot would point at the room the
                  --  other name holds, and the two names then share a fate
                  --  neither asked for: a template that writes
                  --  "set ns.last = index" inside a loop keeps the number
                  --  the loop was at, and the loop takes that room back the
                  --  next time round -- so the kept number quietly becomes
                  --  the current one, and a template written to find the
                  --  last question in a conversation finds the first.
                  --
                  --  A list, a message, a tool and a call are positions
                  --  rather than text and carry no room to be taken back.
                  if Slots (Step.Target).Kind = Value_Text then
                     Assign_Text
                       (Step.Offset,
                        Pool (Slots (Step.Target).Offset + 1
                              .. Slots (Step.Target).Offset
                                 + Slots (Step.Target).Length));
                  else
                     Slots (Step.Offset) := Slots (Step.Target);
                  end if;
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
