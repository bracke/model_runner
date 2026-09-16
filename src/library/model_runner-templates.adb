with Ada.Calendar.Formatting;
with Ada.Calendar.Time_Zones;
with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Exceptions;
with Ada.Unchecked_Deallocation;
with Interfaces.C;
with Interfaces.C.Strings;

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

      --  And everything the last compile learnt about the template it read,
      --  which is not storage and was therefore not being released. A
      --  Compiled is compiled into more than once -- a chat format named on
      --  the command line replaces a model's own that way -- and what was
      --  left behind was the name table and the slots that point into it.
      --  The visible cost was a template that never mentions tools
      --  answering that it reads them, because the template before it did:
      --  a caller offering tools to such a format was told nothing and had
      --  them dropped, which is the fault the question exists to prevent.
      --  The unseen cost was thirty-two names shared between two templates.
      Item.Name_Used := 0;
      Item.Thinking_Slot := 0;
      Item.Tools_Slot := 0;
      Item.Call_Slot := 0;
      Item.Message_Slot := 0;
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
   type Block_Kind is
     (Block_For, Block_If, Block_Macro, Block_Set, Block_Filter, Block_Call);

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

      --  And a loop over the calls one turn asked for, which is the third
      --  thing there is to walk and ends with the third instruction.
      Walks_Calls : Boolean := False;

      --  And a loop over whatever an operand is worth, which keeps its
      --  own state and ends with an instruction of its own.
      Walks_Any   : Boolean := False;

      --  Whether a list loop binds the name a message goes by, which the
      --  name the loop gives its variable decides where the block begins
      --  and both of its instructions have to agree about.
      Binds       : Boolean := True;

      --  The breaks and continues written in a loop's body, chained
      --  through their Target until the endfor says where the Next
      --  instruction is; and, for a filter block, the operand that
      --  filters what was gathered.
      Leaves      : Natural := 0;
      Filter_At   : Natural := 0;
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
         --
         --  Gemma has no system turn: its own template folds a system
         --  message into the first user turn, ahead of what the user said
         --  and a blank line apart, and this does the same. Tools go the
         --  same way, since there is nowhere else for them: the model was
         --  trained on no tool format of its own, so the first user turn
         --  says what functions there are, as JSON one a line, and asks for
         --  a call as a JSON object in <tool_call> tags -- the envelope
         --  Tools.Read_Calls reads and the call grammar constrains. An
         --  assistant turn that asked for tools writes each call that way;
         --  a run of tool answers is folded into one user turn between
         --  <tool_response> tags, Gemma having no tool role either.
         --
         --  A turn's content is trimmed, as the model's own template
         --  trims it; the system message folded in front is not, as it
         --  is not there either.
         --
         --  The line break that ends the role is written inside each branch
         --  rather than after the endif, because a line break standing
         --  straight after a block tag belongs to the template's own shape
         --  and is taken off. Written here it is text, which is what it is:
         --  the break between a turn's role and its content.
         return
           "{{ bos_token }}"
           & "{% if messages[0]['role'] == 'system' %}"
           & "{% set turns = messages[1:] %}"
           & "{% else %}"
           & "{% set turns = messages %}"
           & "{% endif %}"
           & "{% for message in turns %}"
           & "{% if message.role == 'tool' %}"
           & "{% if not loop.first"
           & " and turns[loop.index0 - 1].role != 'tool' %}"
           & "<start_of_turn>user" & LF
           & "{% endif %}"
           & "<tool_response>" & LF
           & "{{ message.content }}" & LF
           & "</tool_response>" & LF
           & "{% if loop.last"
           & " or turns[loop.index0 + 1].role != 'tool' %}"
           & "<end_of_turn>" & LF
           & "{% endif %}"
           & "{% elif message.role == 'assistant' %}"
           & "<start_of_turn>model" & LF
           & "{{ message.content | trim }}"
           & "{% if message.tool_calls %}"
           & "{% for tool_call in message.tool_calls %}"
           & "<tool_call>" & LF
           & "{""name"": ""{{ tool_call.name }}"", ""arguments"": "
           & "{{ tool_call.arguments | tojson }}}" & LF
           & "</tool_call>"
           & "{% endfor %}"
           & "{% endif %}"
           & "<end_of_turn>" & LF
           & "{% else %}"
           & "<start_of_turn>{{ message.role }}" & LF
           & "{% if loop.first %}"
           & "{% if messages[0]['role'] == 'system' %}"
           & "{{ messages[0]['content'] }}" & LF & LF
           & "{% endif %}"
           & "{% if tools %}"
           & "You have access to the following functions. To call one, "
           & "reply with a JSON object inside <tool_call> tags and nothing "
           & "else:" & LF
           & "<tool_call>" & LF
           & "{""name"": ""function-name"", ""arguments"": "
           & "{""parameter-name"": ""value""}}" & LF
           & "</tool_call>" & LF
           & "The function's result comes back inside <tool_response> tags; "
           & "wait for it, then answer from it. If no function is needed, "
           & "answer directly." & LF
           & "Functions:" & LF
           & "{% for tool in tools %}{{ tool | tojson }}" & LF
           & "{% endfor %}" & LF & LF
           & "{% endif %}"
           & "{% endif %}"
           & "{{ message.content | trim }}<end_of_turn>" & LF
           & "{% endif %}"
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

      elsif Name = Format_Name (Format_Qwen3_Coder) then
         --  Carried because the model's own template will not compile -- it
         --  opens with a macro and walks the parameters of a tool as a
         --  mapping. What is written here is that template said in the subset,
         --  tools and all: the tools offered inside a <tools> block, the exact
         --  call-format instructions the model was trained on, and a call
         --  written as <tool_call><function=name>...<parameter=k>v</parameter>
         --  ...</function></tool_call> by the qwen_params filter, which stands
         --  in for the arguments mapping-walk. The calls are read back by
         --  Tools.Read_Calls in its Qwen_XML syntax.
         --
         --  The tools are offered as the model's own template offers them:
         --  a <function> element per tool with its parameters walked as
         --  the schema holds them, which the qwen_tool filter writes from
         --  the definition's JSON, and the same call-format instructions,
         --  byte for byte. Crossed against jinja2 reading the model's own
         --  template with tools, calls and tool answers.
         --
         --  The Qwen3.5 family, whose calls take the same shape, stands on
         --  this format too, and reasons where Qwen3-Coder does not. Its
         --  own template opens the reasoning block for a caller who asked
         --  for it and writes the empty one for a caller who asked it off;
         --  so does this, and only when asked -- a caller who says nothing
         --  gets the generation prompt Qwen3-Coder was trained on, and a
         --  Qwen3.5 then decides for itself, as it does unasked.
         return
           "{% if messages[0]['role'] == 'system' %}"
           & "<|im_start|>system" & LF & "{{ messages[0]['content'] }}"
           & "{% elif tools %}"
           & "<|im_start|>system" & LF
           & "You are Qwen, a helpful AI assistant that can interact with a "
           & "computer to solve tasks."
           & "{% endif %}"
           --  +%} where a line break follows a block tag and is meant:
           --  the engine takes the line break after a block tag off, as
           --  the implementation these templates are written for does,
           --  and the model's own template writes these as expressions,
           --  which keep theirs.
           & "{% if tools +%}"
           & LF & LF
           & "You have access to the following functions:" & LF & LF
           & "<tools>"
           & "{% for tool in tools %}{{ tool | qwen_tool }}"
           & "{% endfor +%}" & LF & "</tools>" & LF & LF
           & "If you choose to call a function ONLY reply in the following "
           & "format with NO suffix:" & LF & LF
           & "<tool_call>" & LF & "<function=example_function_name>" & LF
           & "<parameter=example_parameter_1>" & LF & "value_1" & LF
           & "</parameter>" & LF
           & "<parameter=example_parameter_2>" & LF
           & "This is the value for the second parameter" & LF
           & "that can span" & LF & "multiple lines" & LF
           & "</parameter>" & LF & "</function>" & LF & "</tool_call>" & LF & LF
           & "<IMPORTANT>" & LF & "Reminder:" & LF
           & "- Function calls MUST follow the specified format: an inner "
           & "<function=...></function> block must be nested within "
           & "<tool_call></tool_call> XML tags" & LF
           & "- Required parameters MUST be specified" & LF
           & "- You may provide optional reasoning for your function call in "
           & "natural language BEFORE the function call, but NOT after" & LF
           & "- If there is no function call available, answer the question "
           & "like normal with your current knowledge and do not tell the "
           & "user about function calls" & LF & "</IMPORTANT>"
           & "{% endif %}"
           & "{% if messages[0]['role'] == 'system' or tools %}"
           & "<|im_end|>" & LF
           & "{% endif %}"
           & "{% if messages[0]['role'] == 'system' %}"
           & "{% set turns = messages[1:] %}"
           & "{% else %}"
           & "{% set turns = messages %}"
           & "{% endif %}"
           --  Where the last thing the user said stands, so that the
           --  reasoning an assistant turn carries is kept only after it,
           --  as Qwen3.5's own template keeps it: a turn from an earlier
           --  exchange is written without its <think> block, and one from
           --  the exchange in progress with it.
           & "{% set ns = namespace(last_query_index=-1) %}"
           & "{% for message in turns %}"
           & "{% if message.role == 'user' %}"
           & "{% set ns.last_query_index = loop.index0 %}"
           & "{% endif %}"
           & "{% endfor %}"
           & "{% for message in turns %}"
           & "{% if message.role == 'tool' %}"
           & "{% if not loop.first"
           & " and turns[loop.index0 - 1].role != 'tool' %}"
           & "<|im_start|>user" & LF
           & "{% endif %}"
           & "<tool_response>" & LF
           & "{{ message.content }}" & LF
           & "</tool_response>" & LF
           & "{% if loop.last"
           & " or turns[loop.index0 + 1].role != 'tool' %}"
           & "<|im_end|>" & LF
           & "{% endif %}"
           & "{% elif message.role == 'assistant' and message.tool_calls %}"
           --  A turn that called tools, as the model's own template writes
           --  it: the text trimmed and on a line of its own when there is
           --  any, then each call, and no reasoning block -- that template
           --  writes none for such a turn.
           & "<|im_start|>assistant"
           & "{% if message.content | trim +%}"
           & LF & "{{ message.content | trim }}" & LF
           & "{% endif %}"
           & "{% for tool_call in message.tool_calls +%}"
           & LF & "<tool_call>" & LF & "<function=" & "{{ tool_call.name }}"
           & ">" & LF & "{{ tool_call.arguments | qwen_params }}"
           & "</function>" & LF & "</tool_call>"
           & "{% endfor %}"
           & "<|im_end|>" & LF
           & "{% elif message.role == 'assistant' %}"
           & "{% if '</think>' in message.content %}"
           & "{% set reasoning = message.content.split('</think>')[0]"
           & ".rstrip('\n').split('<think>')[-1].lstrip('\n') %}"
           & "{% set content = message.content.split('</think>')[-1]"
           & ".lstrip('\n') %}"
           & "{% else %}"
           & "{% set reasoning = '' %}"
           & "{% set content = message.content %}"
           & "{% endif %}"
           & "<|im_start|>assistant" & LF
           & "{% if loop.index0 > ns.last_query_index and reasoning %}"
           & "<think>" & LF & "{{ reasoning }}" & LF & "</think>" & LF & LF
           & "{% endif %}"
           & "{{ content }}"
           & "<|im_end|>" & LF
           & "{% else %}"
           & "<|im_start|>{{ message.role }}" & LF
           & "{{ message.content }}<|im_end|>" & LF
           & "{% endif %}"
           & "{% endfor %}"
           & "{% if add_generation_prompt %}"
           & "<|im_start|>assistant" & LF
           & "{% if enable_thinking is defined and enable_thinking is true %}"
           & "<think>" & LF
           & "{% elif enable_thinking is defined %}"
           & "<think>" & LF & LF & "</think>" & LF & LF
           & "{% endif %}"
           & "{% endif %}";

      elsif Name = Format_Name (Format_MiniCPM) then
         --  MiniCPM5, carried for the same reason as Qwen3-Coder: the model's
         --  own template will not compile -- it captures blocks into set,
         --  steps a slice backwards and reaches for string methods this
         --  engine does not carry. What is written here is that template said
         --  in the subset, tools and all.
         --
         --  A system turn opens the prompt; when tools are offered it also
         --  carries the <tools> block -- each tool written with tojson,
         --  wrapped in the usage guidelines MiniCPM was trained on. Turns are
         --  ChatML's; an assistant turn that asked for tools writes each call
         --  as a <function> element, its arguments turned into <param>
         --  children by the params filter, which is what stands in for the
         --  mapping walk the model's own template does. A run of tool answers
         --  is folded into one user turn between <tool_response> tags. The
         --  call a model writes is read back by Tools.Read_Calls in its
         --  Function_XML syntax.
         return
           "{{ bos_token }}"
           & "{% if messages[0]['role'] == 'system' or tools %}"
           & "<|im_start|>system" & LF
           & "{% if messages[0]['role'] == 'system' %}"
           & "{{ messages[0]['content'] }}"
           & "{% if tools +%}" & LF & LF & "{% endif %}"
           & "{% endif %}"
           & "{% if tools %}"
           & "# Tools" & LF & LF
           & "You are provided with function signatures within "
           & "<tools></tools> XML tags:" & LF
           & "<tools>"
           & "{% for tool in tools +%}" & LF & "{{ tool | tojson }}"
           & "{% endfor +%}" & LF
           & "</tools>" & LF & LF
           & "Tool usage guidelines:" & LF
           & "- You may call zero or more functions. If no function calls are "
           & "needed, just answer normally and do not include any "
           & "<function ... </function>." & LF
           & "- When calling a function, return an XML object within "
           & "<function ... </function> using:" & LF
           & "<function name=""function-name""><param name=""param-name"">"
           & "param-value</param></function>" & LF
           & "- param-value may be multi-line. If it contains <, & or newline "
           & "characters, wrap it in a CDATA block: "
           & "<param name=""param-name""><![CDATA[...multi-line value...]]>"
           & "</param>"
           & "{% endif %}"
           & "<|im_end|>" & LF
           & "{% endif %}"
           & "{% if messages[0]['role'] == 'system' %}"
           & "{% set turns = messages[1:] %}"
           & "{% else %}"
           & "{% set turns = messages %}"
           & "{% endif %}"
           --  As the model's own template does, and as qwen3-coder does
           --  here: an assistant turn's reasoning is written only after the
           --  last thing the user said, so an earlier exchange's <think>
           --  block is dropped and the one in progress is kept.
           & "{% set ns = namespace(last_query_index=-1) %}"
           & "{% for message in turns %}"
           & "{% if message.role == 'user' %}"
           & "{% set ns.last_query_index = loop.index0 %}"
           & "{% endif %}"
           & "{% endfor %}"
           & "{% for message in turns %}"
           & "{% if message.role == 'tool' %}"
           --  As the model's own template folds a run of answers: the user
           --  marker before the first, each answer led by a line break,
           --  and the end marker straight after the last.
           & "{% if not loop.first"
           & " and turns[loop.index0 - 1].role != 'tool' %}"
           & "<|im_start|>user"
           & "{% endif +%}"
           & LF & "<tool_response>" & LF
           & "{{ message.content }}" & LF
           & "</tool_response>"
           & "{% if loop.last"
           & " or turns[loop.index0 + 1].role != 'tool' %}"
           & "<|im_end|>" & LF
           & "{% endif %}"
           & "{% elif message.role == 'assistant' %}"
           & "{% if '</think>' in message.content %}"
           & "{% set reasoning = message.content.split('</think>')[0]"
           & ".rstrip('\n').split('<think>')[-1].lstrip('\n') %}"
           & "{% set content = message.content.split('</think>')[-1]"
           & ".lstrip('\n') %}"
           & "{% else %}"
           & "{% set reasoning = '' %}"
           & "{% set content = message.content %}"
           & "{% endif %}"
           & "<|im_start|>assistant" & LF
           & "{% if loop.index0 > ns.last_query_index and reasoning %}"
           & "<think>" & LF & "{{ reasoning }}" & LF & "</think>" & LF & LF
           & "{% endif %}"
           & "{{ content }}"
           & "{% if message.tool_calls %}"
           & "{% for tool_call in message.tool_calls %}"
           & "{% if (loop.first and content) or not loop.first +%}"
           & LF
           & "{% endif %}"
           & "<function name=""{{ tool_call.name }}"">"
           & "{{ tool_call.arguments | params }}</function>"
           & "{% endfor %}"
           & "{% endif %}"
           & "<|im_end|>" & LF
           & "{% else %}"
           & "<|im_start|>{{ message.role }}" & LF
           & "{{ message.content }}<|im_end|>" & LF
           & "{% endif %}"
           & "{% endfor %}"
           & "{% if add_generation_prompt %}"
           & "<|im_start|>assistant" & LF
           & "{% if enable_thinking is defined and enable_thinking is true %}"
           & "<think>" & LF
           & "{% elif enable_thinking is defined %}"
           & "<think>" & LF & LF & "</think>" & LF & LF
           & "{% endif %}"
           & "{% endif %}";
      else
         return "";
      end if;
   end Built_In;

   ---------------
   -- Recognise --
   ---------------

   function Recognise (Source : String) return String is
      function Has (Marker : String) return Boolean
      is (Ada.Strings.Fixed.Index (Source, Marker) > 0);
   begin
      --  The two tool-call shapes before the turn markers, because both of
      --  those templates open their turns the ChatML way. Phi3 is asked for
      --  by its end-of-turn token beside the assistant marker: the
      --  Zephyr-style templates share its <|user|> and <|assistant|> markers
      --  and close a turn with </s>, and the carried phi3 writes the role by
      --  interpolation, so <|user|> is not literal in it.
      if Has ("<function=") and then Has ("<parameter=") then
         return Format_Name (Format_Qwen3_Coder);
      elsif Has ("<function name=") and then Has ("<param name=") then
         return Format_Name (Format_MiniCPM);
      elsif Has ("<|start_header_id|>") then
         return Format_Name (Format_Llama3);
      elsif Has ("<start_of_turn>") then
         return Format_Name (Format_Gemma);
      elsif Has ("<|im_start|>") then
         return Format_Name (Format_ChatML);
      elsif Has ("<|assistant|>") and then Has ("<|end|>") then
         return Format_Name (Format_Phi3);
      else
         return "";
      end if;
   end Recognise;

   ---------------
   -- Syntax_Of --
   ---------------

   function Syntax_Of (Name : String) return Model_Runner.Tools.Call_Syntax
   is (if Name = Format_Name (Format_Qwen3_Coder)
       then Model_Runner.Tools.Qwen_XML
       elsif Name = Format_Name (Format_MiniCPM)
       then Model_Runner.Tools.Function_XML
       elsif Name = Format_Name (Format_Gemma)
       then Model_Runner.Tools.Open_JSON
       else Model_Runner.Tools.Tool_Call_JSON);

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
      is
         At_If   : constant Natural := Top_Level_Word (Held, "if");
         At_Else : constant Natural :=
           (if At_If = 0 then 0 else Top_Level_Word (Held, "else"));
         Test    : Condition;
         Valid   : Boolean;
         Kept    : Natural;
      begin
         Result := (others => <>);
         Ok := False;

         if At_If /= 0 and then (At_Else = 0 or else At_Else > At_If) then
            declare
               Taken_Text : constant String := Held (Held'First .. At_If - 1);
               Test_Text  : constant String :=
                 (if At_Else = 0 then Held (At_If + 2 .. Held'Last)
                  else Held (At_If + 2 .. At_Else - 1));
               Other_Text : constant String :=
                 (if At_Else = 0 then ""
                  else Held (At_Else + 4 .. Held'Last));
               Taken, Other : Operand;
               Scan : Natural := Taken_Text'First;
               Read : Boolean;
            begin
               Read_Operand (Taken_Text, Scan, Taken, Read);
               if not Read
                 or else Skip_Spaces (Taken_Text, Scan) <= Taken_Text'Last
               then
                  return;
               end if;
               Read_Condition (Test_Text, Test, Valid);
               if not Valid then
                  return;
               end if;
               Keep (Taken, Kept);
               if Kept = 0 then
                  return;
               end if;
               Result.Kind := Term_Choice;
               Result.Index_At := Kept;
               Keep (Test, Kept);
               if Kept = 0 then
                  return;
               end if;
               Result.Offset := Kept;
               if Model_Runner.Text.Trim (Other_Text) /= "" then
                  Scan := Other_Text'First;
                  Read_Operand (Other_Text, Scan, Other, Read);
                  if not Read
                    or else Skip_Spaces (Other_Text, Scan) <= Other_Text'Last
                  then
                     return;
                  end if;
                  Keep (Other, Kept);
                  if Kept = 0 then
                     return;
                  end if;
                  Result.Length := Kept;
               end if;
               Ok := True;
               return;
            end;
         end if;

         --  "A or B" and "A and B" where both sides are operands: one
         --  side or the other, as the language answers them. Anything
         --  with a comparison in it is not two operands and goes on to be
         --  read as the condition it is.
         declare
            At_Or  : constant Natural := Top_Level_Word (Held, "or");
            At_And : constant Natural := Top_Level_Word (Held, "and");
            At_Word : constant Natural :=
              (if At_Or /= 0 and then (At_And = 0 or else At_Or < At_And)
               then At_Or else At_And);
            Width  : constant Natural := (if At_Word = At_Or then 2 else 3);
         begin
            if At_Word /= 0 then
               declare
                  Left_Text  : constant String := Held (Held'First .. At_Word - 1);
                  Right_Text : constant String :=
                    Held (At_Word + Width .. Held'Last);
                  Left, Right : Operand;
                  Scan : Natural := Left_Text'First;
                  Read : Boolean;
               begin
                  Read_Operand (Left_Text, Scan, Left, Read);
                  if Read
                    and then Skip_Spaces (Left_Text, Scan) > Left_Text'Last
                  then
                     Scan := Right_Text'First;
                     Read_Operand (Right_Text, Scan, Right, Read);
                     if Read
                       and then Skip_Spaces (Right_Text, Scan) > Right_Text'Last
                     then
                        Keep (Left, Kept);
                        if Kept = 0 then
                           return;
                        end if;
                        Result.Index_At := Kept;
                        Keep (Right, Kept);
                        if Kept = 0 then
                           return;
                        end if;
                        Result.Length := Kept;
                        Result.Kind :=
                          (if At_Word = At_Or then Term_Or else Term_And);
                        Ok := True;
                        return;
                     end if;
                  end if;
               end;
            end if;
         end;

         Read_Condition (Held, Test, Valid);
         if not Valid then
            return;
         end if;
         Keep (Test, Kept);
         if Kept = 0 then
            return;
         end if;
         Result.Kind := Term_Condition;
         Result.Offset := Kept;
         Ok := True;
      end Read_Value_Group;

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

      Method_Names : constant array (1 .. 15) of Method_Name :=
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
         (Capital_Name'Access, Method_Capitalize)];

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
         Second : Natural := 0;
         Piece : Operand;
         Doing_Now : Method_Kind := Doing;
      begin
         Ok := False;

         if Scan > Text'Last or else Text (Scan) /= '(' then
            return;
         end if;

         --  The argument, which is a piece of text or nothing at all: strip
         --  with no argument takes whitespace off, as the language says.
         --  replace takes two, the second after a comma.
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
            if Doing in Method_Replace | Method_Get and then Scan <= Text'Last
              and then Text (Scan) = ','
            then
               declare
                  Other : Operand;
               begin
                  Scan := Scan + 1;
                  Read_Operand (Text, Scan, Other, Taken);
                  if not Taken then
                     return;
                  end if;
                  Keep (Other, Second);
                  if Second = 0 then
                     return;
                  end if;
                  Scan := Skip_Spaces (Text, Scan);
               end;
            end if;
         end if;

         if Scan > Text'Last or else Text (Scan) /= ')' then
            return;
         end if;
         Scan := Scan + 1;

         --  A cut answers with a list, and a template takes one side of it.
         --  Only the two ends are read, because only the two ends are what a
         --  template asks for: what came before the marker, or what came
         --  after the last one. Which end is said either by a position
         --  written after the cut or by a filter written after it, and a
         --  cut that says neither is left unresolved rather than guessed:
         --  it refuses if it is ever read.
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
               Doing_Now := Method_Split_Whole;
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
           (Kind => Doing_Now, At_Operand => Kept, Second_At => Second);
         From := Scan;
         Ok := True;
      end Add_Method;

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
      is
         Index : Natural := Skip_Spaces (Text, From);
      begin
         Result := (others => <>);
         Ok := False;

         if Index > Text'Last then
            return;
         end if;

         --  A bracketed group holding one value, which is a term with
         --  brackets round it and reads as that term: what follows the
         --  closing bracket is written after the group and applies to what
         --  is in it, which is how a template writes
         --  (text.split(marker)|last).lstrip('\n'). A group holding a sum
         --  is not a term and is read where an operand is.
         if Text (Index) = '(' then
            declare
               Shut  : constant Natural := Closes_At (Text, Index);
               Inner : Operand;
               Read  : Boolean;
            begin
               if Shut = 0 or else Group_Depth >= Max_Depth then
                  return;
               end if;

               declare
                  Held : constant String := Text (Index + 1 .. Shut - 1);
                  Scan : Natural := Held'First;
               begin
                  Group_Depth := Group_Depth + 1;
                  Read_Operand (Held, Scan, Inner, Read);
                  Group_Depth := Group_Depth - 1;

                  if not Read
                    or else Inner.Count /= 1
                    or else Skip_Spaces (Held, Scan) <= Held'Last
                  then
                     return;
                  end if;
               end;

               --  A term with filters on it is kept as a group, so that
               --  what follows the bracket -- "(x | first).name" -- is
               --  applied after the filters and not before them.
               if Inner.Terms (1).Filtered > 0 then
                  declare
                     Kept : Natural;
                  begin
                     Keep (Inner, Kept);
                     if Kept = 0 then
                        return;
                     end if;
                     Result := (others => <>);
                     Result.Kind := Term_Group;
                     Result.Offset := Kept;
                     Result.Numeric := Sums (Inner);
                  end;
               else
                  Result := Inner.Terms (1);
               end if;
               Result.Join := Join_Plus;
               From := Shut + 1;
               Ok := True;
               return;
            end;
         end if;

         --  A list written out: its elements are operands, kept one after
         --  another, and the list is made of what they are worth when it
         --  is read. Empty is a list too, which is what a template writes
         --  to say it was given no tools.
         if Text (Index) = '[' then
            declare
               Shut   : Natural := Index + 1;
               Level  : Natural := 0;
               Quote  : Character := ' ';
            begin
               while Shut <= Text'Last loop
                  if Quote /= ' ' then
                     if Text (Shut) = Quote then
                        Quote := ' ';
                     end if;
                  elsif Text (Shut) in ''' | '"' then
                     Quote := Text (Shut);
                  elsif Text (Shut) = '[' then
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

               --  Read first and kept after, all in a row: an element that
               --  is itself a list keeps its own elements as it is read,
               --  and those must not land between this list's.
               declare
                  Inside : constant String := Text (Index + 1 .. Shut - 1);
                  Scan   : Natural := Inside'First;
                  Given  : Natural := 0;
                  Start  : Natural := 0;
                  Held   : Operand_List;
               begin
                  while Skip_Spaces (Inside, Scan) <= Inside'Last loop
                     declare
                        Read  : Boolean;
                        Next  : Natural;
                     begin
                        if Given >= Max_Literal_Elements then
                           --  Refused where it is read, by name: a list
                           --  longer than this engine holds is outside
                           --  the subset and says so, rather than leaving
                           --  the expression around it unreadable.
                           Result := Refused (Text (Index .. Shut));
                           From := Shut + 1;
                           Ok := True;
                           return;
                        end if;
                        Given := Given + 1;
                        Read_Operand (Inside, Scan, Held (Given), Read);
                        if not Read then
                           return;
                        end if;
                        Next := Skip_Spaces (Inside, Scan);
                        if Next <= Inside'Last then
                           if Inside (Next) /= ',' then
                              return;
                           end if;
                           Scan := Next + 1;
                        else
                           Scan := Next;
                        end if;
                     end;
                  end loop;
                  for Which in 1 .. Given loop
                     declare
                        Kept : Natural;
                     begin
                        Keep (Held (Which), Kept);
                        if Kept = 0 then
                           return;
                        end if;
                        if Start = 0 then
                           Start := Kept;
                        end if;
                     end;
                  end loop;
                  Result.Kind := Term_List;
                  Result.Index_At := Start;
                  Result.Length := Given;
                  From := Shut + 1;
                  Ok := True;
                  return;
               end;
            end;
         end if;

         --  A mapping written out: pairs of a key and a value, each an
         --  operand, kept alternately.
         if Text (Index) = '{' then
            declare
               Shut   : Natural := Index + 1;
               Level  : Natural := 0;
               Quote  : Character := ' ';
            begin
               while Shut <= Text'Last loop
                  if Quote /= ' ' then
                     if Text (Shut) = Quote then
                        Quote := ' ';
                     end if;
                  elsif Text (Shut) in ''' | '"' then
                     Quote := Text (Shut);
                  elsif Text (Shut) in '{' | '[' | '(' then
                     Level := Level + 1;
                  elsif Text (Shut) in '}' | ']' | ')' then
                     exit when Level = 0 and then Text (Shut) = '}';
                     Level := (if Level > 0 then Level - 1 else 0);
                  end if;
                  Shut := Shut + 1;
               end loop;
               if Shut > Text'Last then
                  return;
               end if;

               declare
                  Inside : constant String := Text (Index + 1 .. Shut - 1);
                  Scan   : Natural := Inside'First;
                  Pairs  : Natural := 0;
                  Start  : Natural := 0;
                  Held   : Operand_List;
               begin
                  while Skip_Spaces (Inside, Scan) <= Inside'Last loop
                     declare
                        Read  : Boolean;
                        Next  : Natural;
                     begin
                        if 2 * Pairs + 2 > Max_Literal_Elements then
                           Result := Refused (Text (Index .. Shut));
                           From := Shut + 1;
                           Ok := True;
                           return;
                        end if;
                        Read_Operand (Inside, Scan, Held (2 * Pairs + 1), Read);
                        if not Read then
                           return;
                        end if;
                        Next := Skip_Spaces (Inside, Scan);
                        if Next > Inside'Last or else Inside (Next) /= ':' then
                           return;
                        end if;
                        Scan := Next + 1;
                        Read_Operand (Inside, Scan, Held (2 * Pairs + 2), Read);
                        if not Read then
                           return;
                        end if;
                        Pairs := Pairs + 1;
                        Next := Skip_Spaces (Inside, Scan);
                        if Next <= Inside'Last then
                           if Inside (Next) /= ',' then
                              return;
                           end if;
                           Scan := Next + 1;
                        else
                           Scan := Next;
                        end if;
                     end;
                  end loop;
                  for Which in 1 .. 2 * Pairs loop
                     declare
                        Kept : Natural;
                     begin
                        Keep (Held (Which), Kept);
                        if Kept = 0 then
                           return;
                        end if;
                        if Start = 0 then
                           Start := Kept;
                        end if;
                     end;
                  end loop;
                  Result.Kind := Term_Dict;
                  Result.Index_At := Start;
                  Result.Length := Pairs;
                  From := Shut + 1;
                  Ok := True;
                  return;
               end;
            end;
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

               --  A fraction and an exponent, where the number has them:
               --  1.5, 2.5e-3. The point needs a digit after it, so that
               --  a number in front of a member's name stays two things.
               if Index < Text'Last and then Text (Index) = '.'
                 and then Text (Index + 1) in '0' .. '9'
               then
                  Index := Index + 1;
                  while Index <= Text'Last and then Text (Index) in '0' .. '9'
                  loop
                     Index := Index + 1;
                  end loop;
               end if;
               if Index < Text'Last and then Text (Index) in 'e' | 'E'
                 and then (Text (Index + 1) in '0' .. '9'
                           or else (Text (Index + 1) in '+' | '-'
                                    and then Index + 1 < Text'Last
                                    and then Text (Index + 2) in '0' .. '9'))
               then
                  Index := Index + 2;
                  while Index <= Text'Last and then Text (Index) in '0' .. '9'
                  loop
                     Index := Index + 1;
                  end loop;
               end if;

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

               --  A method is called: a word ending in a method's name
               --  with no brackets after it is a member of that name --
               --  a schema's "items" -- and is read as a path below.
               if Doing /= Method_None
                 and then Tail <= Text'Last and then Text (Tail) = '('
               then
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

               --  A macro the template defined, called with its arguments.
               --  The arguments are operands, kept one after another so
               --  that the term can name them by the first and a count.
               if Tail <= Text'Last and then Text (Tail) = '('
                 and then (Macro_Named (Word) /= 0 or else Word = "caller")
               then
                  declare
                     Shut   : constant Natural := Closes_At (Text, Tail);
                     Inside : constant String :=
                       (if Shut = 0 then "" else Text (Tail + 1 .. Shut - 1));
                     Cursor_At     : Natural := Inside'First;
                     Given  : Natural := 0;
                     Start  : Natural := 0;
                  begin
                     if Shut = 0 then
                        return;
                     end if;
                     --  Each argument a whole expression, up to the next
                     --  comma at the top level; read first and kept
                     --  after, all in a row, for the reason a list's
                     --  elements are.
                     declare
                        Held  : Operand_List;
                     begin
                        while Skip_Spaces (Inside, Cursor_At) <= Inside'Last
                        loop
                           declare
                              Stop : constant Natural :=
                                Comma_After (Inside, Cursor_At);
                              Read : Boolean;
                           begin
                              if Given >= Max_Parameters
                                or else Given >= Max_Literal_Elements
                              then
                                 Result := Refused (Text (First .. Shut));
                                 From := Shut + 1;
                                 Ok := True;
                                 return;
                              end if;
                              Given := Given + 1;
                              Read_Expression
                                (Inside (Cursor_At .. Stop - 1), Held (Given),
                                 Read);
                              if not Read then
                                 Result := Refused (Text (First .. Shut));
                                 From := Shut + 1;
                                 Ok := True;
                                 return;
                              end if;
                              Cursor_At := Stop + 1;
                           end;
                        end loop;
                        for Which in 1 .. Given loop
                           declare
                              Kept : Natural;
                           begin
                              Keep (Held (Which), Kept);
                              if Kept = 0 then
                                 return;
                              end if;
                              if Start = 0 then
                                 Start := Kept;
                              end if;
                           end;
                        end loop;
                     end;
                     Result.Kind := Term_Macro;
                     Result.Offset := Macro_Named (Word);
                     Result.Index_At := Start;
                     Result.Length := Given;
                     From := Shut + 1;
                     Ok := True;
                     return;
                  end;
               end if;

               --  The two functions a template calls: strftime_now for the
               --  date and raise_exception to refuse. Each takes one quoted
               --  argument, kept as a literal; anything else in the
               --  brackets refuses the term where it is read.
               if (Word = "strftime_now" or else Word = "raise_exception")
                 and then Tail <= Text'Last and then Text (Tail) = '('
               then
                  declare
                     Shut     : constant Natural := Closes_At (Text, Tail);
                     Argument : Term;
                     Scan     : Natural;
                     Taken    : Boolean := False;
                  begin
                     if Shut = 0 then
                        return;
                     end if;
                     Scan := Tail + 1;
                     Read_Bare_Term (Text (Tail + 1 .. Shut - 1), Scan,
                                     Argument, Taken);
                     if Taken and then Argument.Kind = Term_Literal
                       and then Skip_Spaces (Text (Tail + 1 .. Shut - 1),
                                             Scan) > Shut - 1
                     then
                        Result.Kind :=
                          (if Word = "strftime_now" then Term_Now
                           else Term_Raise);
                        Result.Offset := Argument.Offset;
                        Result.Length := Argument.Length;
                     else
                        Result := Refused (Text (First .. Shut));
                     end if;
                     From := Shut + 1;
                     Ok := True;
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
                        --  A slice is written the same way as far as the
                        --  opening bracket and is not an index at all: it
                        --  is a cut, read as a method of the name in front
                        --  of it. Leaving here rather than refusing is what
                        --  lets the name be read as a name and the cut as
                        --  what follows it.
                        if Inside'Length = 0
                          or else (for some Letter of Inside => Letter = ':')
                        then
                           goto Not_A_Position;
                        end if;

                        Read_Operand (Inside, Where, Index, Taken);
                        if not Taken
                          or else Skip_Spaces (Inside, Where) <= Inside'Last
                        then
                           return;
                        end if;

                        --  Which field, written either way round: a bracket
                        --  with a quoted name in it, or a dot and the name.
                        --  A message of a list by position and its role or
                        --  content is the term the engine has always had;
                        --  anything else indexed -- a list read out of a
                        --  tool's schema, a turn's calls, the pieces of a
                        --  cut, with whatever path follows -- is a name
                        --  indexed and read at render.
                        declare
                           Dot       : Natural := 0;
                           Tail_From : Natural := 1;
                           Tail_To   : Natural := 0;
                        begin
                           for Position in Word'Range loop
                              if Word (Position) = '.' then
                                 Dot := Position;
                                 exit;
                              end if;
                           end loop;

                           if After <= Text'Last and then Text (After) = '['
                           then
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
                                    elsif Named'Length > 2
                                      and then Named (Named'First) in ''' | '"'
                                    then
                                       Field := 3;
                                       Tail_From := After + 2;
                                       Tail_To := Ends - 2;
                                    else
                                       --  A second position rather than a
                                       --  field: left for the index read
                                       --  after the term.
                                       Field := 3;
                                       Ends := After - 1;
                                    end if;
                                 end;
                                 After := Ends + 1;
                              end;
                           elsif After + 4 <= Text'Last
                             and then Text (After .. After + 4) = ".role"
                             and then Dot = 0
                             and then (After + 5 > Text'Last
                                       or else Text (After + 5) not in
                                                 'a' .. 'z' | '_')
                           then
                              Field := 1;
                              After := After + 5;
                           elsif After + 7 <= Text'Last
                             and then Text (After .. After + 7) = ".content"
                             and then Dot = 0
                             and then (After + 8 > Text'Last
                                       or else Text (After + 8) not in
                                                 'a' .. 'z' | '_' | '.')
                           then
                              Field := 2;
                              After := After + 8;
                           elsif After <= Text'Last and then Text (After) = '.'
                           then
                              --  A path after the index, read to the end
                              --  of the dotted word -- less a method called
                              --  at its end, which is read after the term.
                              declare
                                 Ends : Natural := After + 1;
                              begin
                                 while Ends <= Text'Last
                                   and then (Text (Ends) in 'a' .. 'z'
                                             | 'A' .. 'Z' | '0' .. '9'
                                             | '_' | '.')
                                 loop
                                    Ends := Ends + 1;
                                 end loop;
                                 if Ends <= Text'Last and then Text (Ends) = '('
                                 then
                                    for Named of Method_Names loop
                                       declare
                                          Len : constant Natural :=
                                            Named.Text.all'Length;
                                       begin
                                          if Ends - Len >= After
                                            and then Text (Ends - Len .. Ends - 1)
                                                     = Named.Text.all
                                          then
                                             Ends := Ends - Len;
                                             exit;
                                          end if;
                                       end;
                                    end loop;
                                 end if;
                                 Field := 3;
                                 Tail_From := After + 1;
                                 Tail_To := Ends - 1;
                                 After := Ends;
                              end;
                           else
                              Field := 3;
                           end if;

                           Keep (Index, Kept);
                           if Kept = 0 then
                              return;
                           end if;

                           if Field in 1 | 2 and then Dot = 0 then
                              Result.Kind :=
                                (if Field = 1 then Term_Indexed_Role
                                 else Term_Indexed_Content);

                              --  Which list, so that a template that
                              --  rebinds the name reads the rebound one,
                              --  and where the index was kept.
                              Result.Offset := 0;
                              Result.Index_At := Kept;
                              Result.Length := Slot_Of (Word);
                              if Result.Length = 0 then
                                 Result := Refused (Word);
                              end if;
                           else
                              declare
                                 Head   : constant String :=
                                   (if Dot = 0 then Word
                                    else Word (Word'First .. Dot - 1));
                                 Stored : Boolean := True;
                              begin
                                 Result.Kind := Term_Variable;
                                 Result.Indexes := True;
                                 Result.Index_At := Kept;
                                 Result.Offset := Slot_Of (Head);
                                 if Dot /= 0 then
                                    Store_Literal
                                      (Word (Dot + 1 .. Word'Last),
                                       Result.Path_At, Result.Path_Len,
                                       Stored);
                                 end if;
                                 if Stored and then Field = 1 then
                                    Store_Literal
                                      ("role", Result.Tail_At,
                                       Result.Tail_Len, Stored);
                                 elsif Stored and then Field = 2 then
                                    Store_Literal
                                      ("content", Result.Tail_At,
                                       Result.Tail_Len, Stored);
                                 elsif Stored and then Tail_To >= Tail_From
                                 then
                                    Store_Literal
                                      (Text (Tail_From .. Tail_To),
                                       Result.Tail_At, Result.Tail_Len,
                                       Stored);
                                 end if;
                                 if not Stored or else Result.Offset = 0 then
                                    Result := Refused (Word);
                                 end if;
                              end;
                           end if;
                           From := After;
                           Ok := True;
                           return;
                        end;
                     end;
                  end;
               end if;

               <<Not_A_Position>>

               if Word = "strftime_now" then
                  --  The function named without being called, which is how
                  --  a template asks whether it is there: "strftime_now is
                  --  defined". It is, and answers the empty string if
                  --  printed as it stands.
                  Result.Kind := Term_Now;
               elsif Word = "message.role" then
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
               elsif Word = "loop.length" then
                  Result.Kind := Term_Loop_Length;
                  Result.Numeric := True;
               elsif Word = "loop.revindex0" then
                  Result.Kind := Term_Loop_Rev_Index_Zero;
                  Result.Numeric := True;
               elsif Word = "loop.revindex" then
                  Result.Kind := Term_Loop_Rev_Index_One;
                  Result.Numeric := True;
               elsif Word = "loop.index0" then
                  Result.Kind := Term_Loop_Index_Zero;
                  Result.Numeric := True;
               elsif Word = "loop.index" then
                  Result.Kind := Term_Loop_Index_One;
                  Result.Numeric := True;
               elsif Word = "true" or else Word = "True" then
                  Result.Kind := Term_True;
               elsif Word = "false" or else Word = "False" then
                  Result.Kind := Term_False;
               elsif Word = "none" or else Word = "None" then
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

               elsif Word = "loop.previtem" or else Word = "loop.nextitem"
                 or else Model_Runner.Text.Starts_With (Word, "loop.previtem.")
                 or else Model_Runner.Text.Starts_With (Word, "loop.nextitem.")
               then
                  --  The message before or after the bound one, with
                  --  whatever field is read off it.
                  declare
                     Stored : Boolean := True;
                     Head_Length : constant := 13;
                  begin
                     Result.Kind :=
                       (if Word (Word'First + 5 .. Word'First + 8) = "prev"
                        then Term_Loop_Previous else Term_Loop_Next);
                     if Word'Length > Head_Length then
                        Store_Literal
                          (Word (Word'First + Head_Length + 1 .. Word'Last),
                           Result.Path_At, Result.Path_Len, Stored);
                     end if;
                     if not Stored then
                        Result := Refused (Word);
                     end if;
                  end;
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
               elsif Ada.Strings.Fixed.Index (Word, ".") > Word'First
                 and then Word (Word'Last) /= '.'
                 and then Is_Plain_Name
                            (Word (Word'First
                                   .. Ada.Strings.Fixed.Index (Word, ".") - 1))
               then
                  --  A name and a path of members read off what it holds:
                  --  a mapping's member, a message's field, a call's name
                  --  or arguments. What the name holds is known when the
                  --  render reads it, and so is whether it has the member.
                  declare
                     Dot    : constant Natural :=
                       Ada.Strings.Fixed.Index (Word, ".");
                     Stored : Boolean;
                  begin
                     Result.Kind := Term_Variable;
                     Result.Offset := Slot_Of (Word (Word'First .. Dot - 1));
                     Store_Literal
                       (Word (Dot + 1 .. Word'Last), Result.Path_At,
                        Result.Path_Len, Stored);
                     if Result.Offset = 0 or else not Stored then
                        Result := Refused (Word);
                     end if;
                  end;
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
      --  What may follow a term once it has been read: methods, positions
      --  and members in any order, then filters. A bracketed group takes
      --  the same tail, which is how "(x | list)[0].name" is read.
      procedure Read_Tail
        (Text   : String;
         From   : in out Natural;
         Result : in out Term) is
      begin
         --  Methods written one after another: a template that cuts a reply
         --  at its reasoning marker and then trims what is left writes four
         --  in a row, and each takes what the one before it answered.
         loop
            declare
               Scan  : constant Natural := Skip_Spaces (Text, From);
               Doing : Method_Kind := Method_None;
               Ends  : Natural := 0;
               Taken : Boolean;

               --  Add a cut at a position, the position being an operand of
               --  its own: a template writes one worked out rather than
               --  written down.
               procedure Add_Cut
                 (Source : String; Kind : Method_Kind; Added : out Boolean)
               is
                  Where : Operand;
                  Read  : Boolean;
                  Scan_At : Natural := Source'First;
                  Kept  : Natural;
               begin
                  Added := False;
                  Read_Operand (Source, Scan_At, Where, Read);
                  if not Read
                    or else Skip_Spaces (Source, Scan_At) <= Source'Last
                    or else Result.Chained >= Max_Methods
                  then
                     return;
                  end if;

                  Keep (Where, Kept);
                  if Kept = 0 then
                     return;
                  end if;

                  Result.Chained := Result.Chained + 1;
                  Result.Methods (Result.Chained) :=
                    (Kind => Kind, At_Operand => Kept, Second_At => 0);
                  Added := True;
               end Add_Cut;
            begin
               exit when Scan > Text'Last;

               --  A cut at a position: text[n:], text[:n] and text[a:b].
               --  Both ends are cut where both are written, and the far end
               --  first, because the near one moves what is left of the
               --  text and a position was counted in the text as it was.
               if Text (Scan) = '[' then
                  declare
                     Shut  : Natural := Scan + 1;
                     Level : Natural := 0;
                     Colon : Natural := 0;
                  begin
                     while Shut <= Text'Last loop
                        if Text (Shut) = '[' then
                           Level := Level + 1;
                        elsif Text (Shut) = ']' then
                           exit when Level = 0;
                           Level := Level - 1;
                        elsif Text (Shut) = ':' and then Level = 0
                          and then Colon = 0
                        then
                           Colon := Shut;
                        end if;
                        Shut := Shut + 1;
                     end loop;

                     exit when Shut > Text'Last;

                     --  No colon: one element by position, of whatever
                     --  came before -- a list, a cut, a text.
                     if Colon = 0 then
                        declare
                           Added : Boolean;
                        begin
                           Add_Cut (Text (Scan + 1 .. Shut - 1), Method_Index,
                                    Added);
                           if not Added then
                              Result := Refused (Text (Scan .. Shut));
                           end if;
                           From := Shut + 1;
                           goto Read_On;
                        end;
                     end if;

                     declare
                        Front : constant String :=
                          Model_Runner.Text.Trim (Text (Scan + 1 .. Colon - 1));
                        Back  : constant String :=
                          Model_Runner.Text.Trim (Text (Colon + 1 .. Shut - 1));
                        Added : Boolean := True;
                     begin
                        if Back'Length > 0 then
                           Add_Cut (Back, Method_Cut_To, Added);
                        end if;

                        if Added and then Front'Length > 0 then
                           Add_Cut (Front, Method_Cut_From, Added);
                        end if;

                        if not Added then
                           Result := Refused (Text (Scan .. Shut));
                        end if;
                     end;

                     From := Shut + 1;
                  end;

                  goto Read_On;
               end if;

               exit when Text (Scan) /= '.';

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

               --  A dotted name that is not a method called: one member
               --  of what came before, which is how a path goes on after
               --  an index -- content[0].text.
               if Doing = Method_None
                 or else Ends > Text'Last
                 or else Text (Ends) /= '('
               then
                  declare
                     Stop : Natural := Scan + 1;
                     Named : Operand;
                     Kept  : Natural;
                     Stored : Boolean;
                  begin
                     while Stop <= Text'Last
                       and then Text (Stop) in 'a' .. 'z' | 'A' .. 'Z'
                                               | '0' .. '9' | '_'
                     loop
                        Stop := Stop + 1;
                     end loop;
                     exit when Stop = Scan + 1
                       or else (Stop <= Text'Last and then Text (Stop) = '(')
                       or else Result.Chained >= Max_Methods;

                     Named.Count := 1;
                     Named.Terms (1).Kind := Term_Literal;
                     Store_Literal
                       (Text (Scan + 1 .. Stop - 1), Named.Terms (1).Offset,
                        Named.Terms (1).Length, Stored);
                     exit when not Stored;
                     Keep (Named, Kept);
                     exit when Kept = 0;
                     Result.Chained := Result.Chained + 1;
                     Result.Methods (Result.Chained) :=
                       (Kind => Method_Member, At_Operand => Kept,
                        Second_At => 0);
                     From := Stop;
                     goto Read_On;
                  end;
               end if;

               From := Ends;
               Add_Method (Text, Doing, From, Result, Taken);
               exit when not Taken;

               <<Read_On>>
               null;
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

               if Last < First or else Result.Filtered >= Max_Filters then
                  Result := Refused ("filter", E.Template_Unknown_Filter);

               --  Which piece of a cut text is wanted. A template writes
               --  either text.split(marker)[0] or text.split(marker)|first,
               --  and the two are the same thing: the filter says which end
               --  the cut in front of it keeps, so it is answered by the
               --  cut rather than after it. Written after anything else it
               --  is a list this engine has not got.
               elsif Text (First .. Last) = "first"
                 or else Text (First .. Last) = "last"
               then
                  if Result.Chained > 0 and then Result.Filtered = 0
                    and then Result.Methods (Result.Chained).Kind
                             in Method_Split_First | Method_Split_Last
                                | Method_Split_Whole
                  then
                     Result.Methods (Result.Chained).Kind :=
                       (if Text (First .. Last) = "first"
                        then Method_Split_First else Method_Split_Last);
                  else
                     --  One end of whatever list stands there.
                     Result.Filtered := Result.Filtered + 1;
                     Result.Filters (Result.Filtered) :=
                       (Kind => (if Text (First .. Last) = "first"
                                 then Filter_First else Filter_Last),
                        others => <>);
                  end if;

               else
                  declare
                     Word : constant String := Text (First .. Last);
                     Step : Filter_Step;

                     --  The arguments in brackets after a filter's name,
                     --  each an operand, up to two: what default stands in
                     --  and what replace takes out and puts in. tojson's
                     --  ensure_ascii is taken and ignored, because every
                     --  byte written here is UTF-8 already.
                     --  Up to Wanted of them, Needed at least; a keyword
                     --  argument goes to the slot the language's own order
                     --  gives that keyword for this filter.
                     procedure Read_Arguments
                       (Wanted : Natural; Needed : Natural := Natural'Last)
                     is
                        Opens : constant Natural := Skip_Spaces (Text, From);
                        Shut  : Natural;

                        procedure Put_Argument (Slot : Natural; Kept : Natural)
                        is
                        begin
                           case Slot is
                              when 1 => Step.Arg1 := Kept;
                              when 2 => Step.Arg2 := Kept;
                              when others => Step.Arg3 := Kept;
                           end case;
                        end Put_Argument;

                        function Slot_Of_Keyword (Key : String) return Natural
                        is
                        begin
                           if Key = "attribute" then
                              return (if Word = "sort" then 3 else 1);
                           elsif Key = "reverse" then
                              return (if Word = "dictsort" then 3 else 1);
                           elsif Key = "case_sensitive" then
                              return (if Word = "dictsort" then 1 else 2);
                           elsif Key = "by" then
                              return 2;
                           elsif Key = "width" then
                              return 1;
                           elsif Key = "first" then
                              return 2;
                           elsif Key = "blank" then
                              return 3;
                           elsif Key = "d" or else Key = "default" then
                              return 1;
                           elsif Key = "indent" then
                              return 1;
                           elsif Key = "ensure_ascii" or else Key = "sort_keys"
                           then
                              --  Taken and ignored: every byte written
                              --  here is UTF-8 already, and a mapping is
                              --  written in the order it holds.
                              return 2;
                           end if;
                           return 0;
                        end Slot_Of_Keyword;
                     begin
                        if Opens > Text'Last or else Text (Opens) /= '(' then
                           if Wanted > 0
                             and then Natural'Min (Wanted, Needed) > 0
                           then
                              Result :=
                                Refused (Word, E.Template_Unknown_Filter);
                           end if;
                           return;
                        end if;

                        Shut := Closes_At (Text, Opens);
                        if Shut = 0 then
                           Result := Refused (Word, E.Template_Unknown_Filter);
                           return;
                        end if;

                        declare
                           Inside : constant String :=
                             Text (Opens + 1 .. Shut - 1);
                           Scan   : Natural := Inside'First;
                           Found  : Natural := 0;
                        begin
                           while Found < Wanted
                             and then Skip_Spaces (Inside, Scan) <= Inside'Last
                           loop
                              declare
                                 Value : Operand;
                                 Read  : Boolean;
                                 Kept  : Natural;
                                 Slot  : Natural := Found + 1;
                                 Key_First, Key_Last : Natural;
                                 Ahead : Natural := Scan;
                              begin
                                 --  name=value: the slot is the keyword's.
                                 Read_Word (Inside, Ahead, Key_First, Key_Last);
                                 if Key_Last >= Key_First
                                   and then Skip_Spaces (Inside, Ahead)
                                            <= Inside'Last
                                   and then Inside (Skip_Spaces (Inside, Ahead))
                                            = '='
                                   and then (Skip_Spaces (Inside, Ahead) + 1
                                             > Inside'Last
                                             or else Inside
                                                       (Skip_Spaces (Inside, Ahead)
                                                        + 1) /= '=')
                                 then
                                    Slot := Slot_Of_Keyword
                                              (Inside (Key_First .. Key_Last));
                                    if Slot = 0 then
                                       Result :=
                                         Refused (Word, E.Template_Unknown_Filter);
                                       return;
                                    end if;
                                    Scan := Skip_Spaces (Inside, Ahead) + 1;
                                 end if;

                                 Read_Operand (Inside, Scan, Value, Read);
                                 if not Read then
                                    Result :=
                                      Refused (Word, E.Template_Unknown_Filter);
                                    return;
                                 end if;
                                 Keep (Value, Kept);
                                 if Kept = 0 then
                                    Result :=
                                      Refused (Word, E.Template_Unknown_Filter);
                                    return;
                                 end if;
                                 Found := Found + 1;
                                 Put_Argument (Slot, Kept);
                              end;
                              Scan := Skip_Spaces (Inside, Scan);
                              if Scan <= Inside'Last then
                                 if Inside (Scan) /= ',' then
                                    Result :=
                                      Refused (Word, E.Template_Unknown_Filter);
                                    return;
                                 end if;
                                 Scan := Scan + 1;
                              end if;
                           end loop;
                           if Found < Natural'Min (Wanted, Needed) then
                              Result :=
                                Refused (Word, E.Template_Unknown_Filter);
                              return;
                           end if;
                        end;
                        From := Shut + 1;
                     end Read_Arguments;
                  begin
                     if Word = "trim" then
                        Step.Kind := Filter_Trim;
                     elsif Word = "length" then
                        Step.Kind := Filter_Length;
                        Result.Numeric := True;
                     elsif Word = "tojson" then
                        Step.Kind := Filter_JSON;
                        Read_Arguments (2, 0);
                     elsif Word = "params" then
                        Step.Kind := Filter_Params;
                     elsif Word = "qwen_params" then
                        Step.Kind := Filter_Qwen_Params;
                     elsif Word = "qwen_tool" then
                        Step.Kind := Filter_Qwen_Tool;
                     elsif Word = "lower" then
                        Step.Kind := Filter_Lower;
                     elsif Word = "upper" then
                        Step.Kind := Filter_Upper;
                     elsif Word = "capitalize" then
                        Step.Kind := Filter_Capitalize;
                     elsif Word = "title" then
                        Step.Kind := Filter_Title;
                     elsif Word = "int" then
                        Step.Kind := Filter_Int;
                        Result.Numeric := True;
                        Read_Arguments (0);
                     elsif Word = "float" then
                        Step.Kind := Filter_Float;
                        Result.Numeric := True;
                        Read_Arguments (0);
                     elsif Word = "string" then
                        Step.Kind := Filter_String;
                     elsif Word = "safe" then
                        Step.Kind := Filter_Safe;
                     elsif Word = "default" or else Word = "d" then
                        Step.Kind := Filter_Default;
                        Read_Arguments (1);
                     elsif Word = "replace" then
                        Step.Kind := Filter_Replace;
                        Read_Arguments (2);
                     elsif Word = "min" then
                        Step.Kind := Filter_Min;
                        Result.Numeric := True;
                     elsif Word = "join" then
                        Step.Kind := Filter_Join;
                        Read_Arguments (2, 0);
                     elsif Word = "map" then
                        Step.Kind := Filter_Map;
                        Read_Arguments (1, 1);
                     elsif Word = "select" then
                        Step.Kind := Filter_Select;
                        Read_Arguments (2, 0);
                     elsif Word = "reject" then
                        Step.Kind := Filter_Reject;
                        Read_Arguments (2, 0);
                     elsif Word = "selectattr" then
                        Step.Kind := Filter_Select_Attr;
                        Read_Arguments (3, 1);
                     elsif Word = "rejectattr" then
                        Step.Kind := Filter_Reject_Attr;
                        Read_Arguments (3, 1);
                     elsif Word = "sort" then
                        Step.Kind := Filter_Sort;
                        Read_Arguments (3, 0);
                     elsif Word = "dictsort" then
                        Step.Kind := Filter_Dict_Sort;
                        Read_Arguments (3, 0);
                     elsif Word = "indent" then
                        Step.Kind := Filter_Indent;
                        Read_Arguments (3, 0);
                     elsif Word = "unique" then
                        Step.Kind := Filter_Unique;
                        Read_Arguments (0);
                     elsif Word = "list" then
                        Step.Kind := Filter_List;
                        Read_Arguments (0);
                     elsif Word = "items" then
                        --  A filter spelling of the method, and the same
                        --  thing: the mapping, to be walked entry by entry.
                        if Result.Chained < Max_Methods then
                           Result.Chained := Result.Chained + 1;
                           Result.Methods (Result.Chained) :=
                             (Kind => Method_Items, At_Operand => 0,
                              Second_At => 0);
                        end if;
                        Step.Kind := Filter_None;
                     else
                        Result := Refused (Word, E.Template_Unknown_Filter);
                     end if;

                     if Result.Kind /= Term_Unsupported then
                        Result.Filtered := Result.Filtered + 1;
                        Result.Filters (Result.Filtered) := Step;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end Read_Tail;

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
                  when '*' => Joined := Join_Times;
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
                  when others => Joined := Join_Plus;
               end case;
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

         --  The block form, a name and nothing after it: what is written
         --  up to the endset is the name's value rather than the prompt's.
         if Target /= 0 and then Skip_Spaces (Text, Scan) > Text'Last then
            if Depth >= Max_Depth then
               Fail (E.Template_Nesting_Too_Deep, "set");
               return;
            end if;
            Emit ((Op => Op_Capture_Begin, others => <>), Where);
            if Where = 0 then
               return;
            end if;
            Depth := Depth + 1;
            Frames (Depth) := (Kind => Block_Set, Start => Target,
                               others => <>);
            return;
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
                       and then Inside (Inside'First) not in ''' | '"'
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

               --  A choice written on one line: A if C else B. Templates
               --  write it where a turn may not carry the field they are
               --  after -- message.content if message.content is defined
               --  else '' -- and what it compiles to is what the block form
               --  compiles to, because it is the block form said in one
               --  line: the condition, a jump over the first assignment,
               --  and a jump over the second.
               declare
                  At_If   : constant Natural := Word_At (Rest, "if");
                  At_Else : constant Natural :=
                    (if At_If = 0 then 0 else Word_At (Rest, "else", At_If + 2));
               begin
                  if At_If > Rest'First and then At_Else /= 0
                    and then Word_At (Rest, "if", At_Else + 4) = 0
                  then
                     declare
                        Whether : constant String :=
                          Model_Runner.Text.Trim
                            (Rest (At_If + 2 .. At_Else - 1));
                        Chosen  : constant String :=
                          Model_Runner.Text.Trim
                            (Rest (Rest'First .. At_If - 1));
                        Otherwise : constant String :=
                          Model_Runner.Text.Trim
                            (Rest (At_Else + 4 .. Rest'Last));

                        Test  : Condition;
                        Valid : Boolean;
                        Held  : Natural;
                        Over_First, Over_Second : Natural := 0;

                        --  Assign one side, answering where the
                        --  instruction landed or zero when it could not
                        --  be read or could not be kept.
                        procedure Assign (Source : String; At_Step : out Natural)
                        is
                           Value : Operand;
                           Read  : Boolean;
                           Scan  : Natural := Source'First;
                           Kept  : Natural;
                        begin
                           At_Step := 0;
                           Read_Operand (Source, Scan, Value, Read);
                           if not Read
                             or else Skip_Spaces (Source, Scan) <= Source'Last
                           then
                              return;
                           end if;

                           Keep (Value, Kept);
                           if Kept = 0 then
                              return;
                           end if;
                           Emit ((Op => Op_Set_Value, Offset => Target,
                                  Value_At => Kept, others => <>), At_Step);
                        end Assign;
                     begin
                        Read_Condition (Whether, Test, Valid);
                        if not Valid then
                           Refuse (Text, Where);
                           return;
                        end if;

                        Keep (Test, Held);
                        if Held = 0 then
                           return;
                        end if;

                        Emit ((Op => Op_Jump_If_False, Test_At => Held,
                               others => <>), Over_First);
                        if Over_First = 0 then
                           return;
                        end if;

                        Assign (Chosen, Where);
                        if Where = 0 then
                           Refuse (Text, Where);
                           return;
                        end if;

                        Emit ((Op => Op_Jump, others => <>), Over_Second);
                        if Over_Second = 0 then
                           return;
                        end if;
                        Item.Program.all (Over_First).Target := Over_Second + 1;

                        Assign (Otherwise, Where);
                        if Where = 0 then
                           Refuse (Text, Where);
                           return;
                        end if;
                        Item.Program.all (Over_Second).Target :=
                          Item.Program_Used + 1;
                        return;
                     end;
                  end if;
               end;

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
                     --  Or a comparison assigned, "set ok = a == b".
                     declare
                        Group : Term;
                        Read  : Boolean;
                     begin
                        Read_Value_Group (Rest, Group, Read);
                        if not Read then
                           Refuse (Text, Where);
                           return;
                        end if;
                        Value := (Terms => [1 => Group, others => <>],
                                  Count => 1);
                     end;
                  end if;

                  Keep (Value, Kept);
                  if Kept = 0 then
                     return;
                  end if;
                  Emit ((Op => Op_Set_Value, Offset => Target,
                         Value_At => Kept, others => <>), Where);
               end;
            end;
         end;
      end Compile_Set;

      --  Handle one {% ... %} tag.
      --  {% macro name(p, q='x') %}: the jump over the body, the macro's
      --  entry after it, and its parameters read into the table.
      procedure Compile_Macro (Text : String) is
         Scan        : Natural := Text'First;
         First, Last : Natural;
         Where       : Natural;
         Added       : Macro;
      begin
         Read_Word (Text, Scan, First, Last);
         if Last < First or else not Is_Plain_Name (Text (First .. Last))
           or else Item.Macro_Used >= Max_Macros
           or else Depth >= Max_Depth
         then
            Fail (E.Template_Unsupported_Construct, "macro");
            return;
         end if;

         declare
            Opens  : constant Natural := Skip_Spaces (Text, Scan);
            Shut   : Natural;
            Stored : Boolean;
         begin
            if Opens > Text'Last or else Text (Opens) /= '(' then
               Fail (E.Template_Unsupported_Construct, "macro");
               return;
            end if;
            Shut := Closes_At (Text, Opens);
            if Shut = 0 or else Skip_Spaces (Text, Shut + 1) <= Text'Last then
               Fail (E.Template_Unsupported_Construct, "macro");
               return;
            end if;

            Store_Literal (Text (First .. Last), Added.Name.Offset,
                           Added.Name.Length, Stored);
            if not Stored then
               Fail (E.Template_Too_Large, "source");
               return;
            end if;

            --  The parameters, a name each, with a default after an
            --  equals sign where one is written.
            declare
               Inside : constant String := Text (Opens + 1 .. Shut - 1);
               Cursor_At     : Natural := Inside'First;
            begin
               while Skip_Spaces (Inside, Cursor_At) <= Inside'Last loop
                  declare
                     P_First, P_Last : Natural;
                     Next : Natural;
                  begin
                     Cursor_At := Skip_Spaces (Inside, Cursor_At);
                     Read_Word (Inside, Cursor_At, P_First, P_Last);
                     if P_Last < P_First
                       or else not Is_Plain_Name (Inside (P_First .. P_Last))
                       or else Added.Count >= Max_Parameters
                     then
                        Fail (E.Template_Unsupported_Construct, "macro");
                        return;
                     end if;
                     Added.Count := Added.Count + 1;
                     Added.Slots (Added.Count) :=
                       Slot_Of (Inside (P_First .. P_Last));
                     if Added.Slots (Added.Count) = 0 then
                        Fail (E.Template_Too_Large, "variables");
                        return;
                     end if;

                     Next := Skip_Spaces (Inside, Cursor_At);
                     if Next <= Inside'Last and then Inside (Next) = '=' then
                        declare
                           Value : Operand;
                           Read  : Boolean;
                           Kept  : Natural;
                        begin
                           Cursor_At := Next + 1;
                           Read_Operand (Inside, Cursor_At, Value, Read);
                           if not Read then
                              Fail (E.Template_Unsupported_Construct,
                                    "macro");
                              return;
                           end if;
                           Keep (Value, Kept);
                           if Kept = 0 then
                              return;
                           end if;
                           Added.Defaults (Added.Count) := Kept;
                        end;
                        Next := Skip_Spaces (Inside, Cursor_At);
                     end if;

                     if Next <= Inside'Last then
                        if Inside (Next) /= ',' then
                           Fail (E.Template_Unsupported_Construct, "macro");
                           return;
                        end if;
                        Cursor_At := Next + 1;
                     else
                        Cursor_At := Next;
                     end if;
                  end;
               end loop;
            end;
         end;

         Emit ((Op => Op_Jump, others => <>), Where);
         if Where = 0 then
            return;
         end if;
         Added.Entry_At := Item.Program_Used + 1;

         Item.Macro_Used := Item.Macro_Used + 1;
         Item.Macros (Item.Macro_Used) := Added;

         Depth := Depth + 1;
         Frames (Depth) := (Kind => Block_Macro, Pending => Where,
                            others => <>);
      end Compile_Macro;

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

               --  Whether this loop binds the name a message goes by,
               --  which only a loop over a list naming its variable
               --  message does.
               Binding   : Boolean := False;

               --  Whether it walks the tools instead, or the calls one
               --  turn asked for, and whether it stands inside a loop that
               --  already walks one of those.
               Calling      : Boolean := False;

               --  Or whatever an operand is worth, kept at Each_At, with a
               --  second name for a mapping's keys and walked backwards
               --  where the template says so.
               Walking_Any   : Boolean := False;
               Each_At       : Natural := 0;
               Each_Key      : Natural := 0;
               Each_Reversed : Boolean := False;
               Inside_Calls : constant Boolean :=
                 (for some Level in 1 .. Depth => Frames (Level).Walks_Calls);
            begin
               --  Four loops, told apart by what is looped over. Over a
               --  range of whole numbers the variable holds a number; over
               --  message.tool_calls under the name tool_call it walks the
               --  bound turn's calls with the legacy machinery; over a
               --  plain name under the name message it is the list loop
               --  the engine has always had, binding each turn as it goes;
               --  and over anything else -- the conversation under another
               --  name or backwards, a list read out of a schema, a mapping
               --  two names at a time, the tools -- it walks whatever the
               --  operand is worth when it begins, keeping where it has got
               --  to in its own state, so these nest.
               Counting := False;
               Read_Word (Rest, Scan, First, Last);
               if Last >= First and then Is_Plain_Name (Rest (First .. Last))
               then
                  declare
                     Named : constant String := Rest (First .. Last);
                     Key_First : Natural := 1;
                     Key_Last  : Natural := 0;
                  begin
                     --  A second name after a comma, for a loop that walks
                     --  a mapping entry by entry: the key goes to the
                     --  first name and the value to the second.
                     if Skip_Spaces (Rest, Scan) <= Rest'Last
                       and then Rest (Skip_Spaces (Rest, Scan)) = ','
                     then
                        Scan := Skip_Spaces (Rest, Scan) + 1;
                        Read_Word (Rest, Scan, Key_First, Key_Last);
                        if Key_Last < Key_First
                          or else not Is_Plain_Name (Rest (Key_First .. Key_Last))
                        then
                           Key_Last := 0;
                           Key_First := 1;
                        end if;
                     end if;

                     Read_Word (Rest, Scan, First, Last);
                     if Last >= First and then Rest (First .. Last) = "in" then
                        declare
                           Tail : constant String :=
                             Model_Runner.Text.Trim
                               (Rest (Scan .. Rest'Last));
                           Two_Names : constant Boolean := Key_Last >= Key_First;
                        begin
                           if Model_Runner.Text.Starts_With (Tail, "range(")
                             and then Tail (Tail'Last) = ')'
                             and then not Two_Names
                           then
                              Counting := True;
                              Read_Range
                                (Tail (Tail'First + 6 .. Tail'Last - 1),
                                 Bounds_At, Counted);
                              Over := (if Counted then Slot_Of (Named) else 0);
                           elsif Named = "tool_call" and then not Two_Names
                             and then (Tail = "message.tool_calls"
                                       or else Tail = "message['tool_calls']")
                           then
                              --  The calls the bound turn asked for. Which
                              --  turn that is is known when the render
                              --  runs; that it is the bound one is decided
                              --  here.
                              Calling := True;
                              Over := Slot_Of (Named);
                           elsif Named = "message" and then not Two_Names
                             and then Is_Plain_Name (Tail)
                           then
                              --  The list loop the engine has always had,
                              --  binding the name a turn's fields are read
                              --  through as it goes.
                              Over := Slot_Of (Tail);
                              Binding := True;
                           else
                              --  Anything else: whatever the operand is
                              --  worth when the loop begins -- a list read
                              --  out of a schema, a mapping walked two
                              --  names at a time, the tools, a list of
                              --  messages under another name or backwards,
                              --  a turn's calls. The loop keeps where it
                              --  has got to in its own variable, so these
                              --  nest, inside a loop over the tools
                              --  included.
                              declare
                                 Backwards : constant Boolean :=
                                   Tail'Length > 6
                                   and then Tail (Tail'Last - 5 .. Tail'Last)
                                            = "[::-1]";
                                 Source_Text : constant String :=
                                   (if Backwards
                                    then Tail (Tail'First .. Tail'Last - 6)
                                    else Tail);
                                 Value : Operand;
                                 Read  : Boolean;
                                 Scan_At : Natural := Source_Text'First;
                              begin
                                 Read_Operand (Source_Text, Scan_At, Value, Read);
                                 if Read
                                   and then Skip_Spaces (Source_Text, Scan_At)
                                            > Source_Text'Last
                                 then
                                    Keep (Value, Each_At);
                                    Each_Reversed := Backwards;
                                    Each_Key :=
                                      (if Two_Names
                                       then Slot_Of (Rest (Key_First .. Key_Last))
                                       else 0);
                                    Over :=
                                      (if Each_At = 0
                                         or else (Two_Names and then Each_Key = 0)
                                       then 0 else Slot_Of (Named));
                                    Walking_Any := Over /= 0;
                                 end if;
                              end;
                           end if;

                           --  A legacy loop inside a loop over a turn's
                           --  calls cannot say which loop its loop.first is
                           --  about; the loops that keep their own state can.
                           if Inside_Calls and then not Walking_Any then
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
               elsif Walking_Any then
                  Emit ((Op => Op_Each_Begin, Offset => Over,
                         Length => Each_Key, Value_At => Each_At,
                         Reversed => Each_Reversed, others => <>), Where);
               elsif Calling then
                  Emit ((Op => Op_Call_Begin, Offset => Over, others => <>),
                        Where);
               else
                  Emit ((Op => Op_For_Begin, Offset => Over,
                         Binds => Binding, others => <>),
                        Where);
               end if;
               if Where = 0 then
                  return;
               end if;

               Depth := Depth + 1;
               Frames (Depth) :=
                 (Kind => Block_For, Start => Where, Dead => Over = 0,
                  Numeric => Counting and then Over /= 0,
                  Walks_Calls => Calling and then Over /= 0,
                  Walks_Any => Walking_Any and then Over /= 0,
                  Binds => Binding, others => <>);
               Exit_Chain (Depth) := 0;
            end;

         elsif Trimmed = "endfor" then
            if Depth = 0 or else Frames (Depth).Kind /= Block_For then
               Fail (E.Template_Unbalanced_Block, "endfor");
               return;
            end if;

            if not Frames (Depth).Dead then
               Emit ((Op => (if Frames (Depth).Numeric then Op_Range_Next
                             elsif Frames (Depth).Walks_Calls then Op_Call_Next
                             elsif Frames (Depth).Walks_Any then Op_Each_Next
                             else Op_For_Next),
                      Target => Frames (Depth).Start,
                      Binds => Frames (Depth).Binds, others => <>), Where);
               if Where = 0 then
                  return;
               end if;
               Item.Program.all (Frames (Depth).Start).Target := Where + 1;

               --  Every break and continue in the body jumps here.
               declare
                  Link : Natural := Frames (Depth).Leaves;
                  Next : Natural;
               begin
                  while Link /= 0 loop
                     Next := Item.Program.all (Link).Target;
                     Item.Program.all (Link).Target := Where;
                     Link := Next;
                  end loop;
               end;
            end if;
            Depth := Depth - 1;

         elsif Trimmed = "break" or else Trimmed = "continue" then
            --  Inside the innermost loop, whatever blocks stand between:
            --  chained on that loop's frame until its endfor is read.
            declare
               Level : Natural := Depth;
            begin
               while Level > 0 and then Frames (Level).Kind /= Block_For loop
                  Level := Level - 1;
               end loop;
               if Level = 0 then
                  Fail (E.Template_Unbalanced_Block, Trimmed);
                  return;
               end if;
               if not Frames (Level).Dead then
                  Emit ((Op => (if Trimmed = "break" then Op_Break
                                else Op_Continue),
                         Target => Frames (Level).Leaves, others => <>),
                        Where);
                  if Where = 0 then
                     return;
                  end if;
                  Frames (Level).Leaves := Where;
               end if;
            end;

         elsif Model_Runner.Text.Starts_With (Trimmed, "filter ") then
            --  What is written up to the endfilter, gathered into a name
            --  of the block's own and written out through the filter:
            --  the same door a block set and a filtered name go through.
            declare
               Named  : constant String :=
                 "__filter" & Model_Runner.Text.Image
                   (Long_Long_Integer (Item.Program_Used));
               Target : constant Natural := Slot_Of (Named);
               Source : constant String :=
                 Named & " | "
                 & Model_Runner.Text.Trim
                     (Trimmed (Trimmed'First + 7 .. Trimmed'Last));
               Value  : Operand;
               Scan   : Natural := Source'First;
               Valid  : Boolean;
               Kept   : Natural := 0;
            begin
               if Target = 0 or else Depth >= Max_Depth then
                  Fail (E.Template_Nesting_Too_Deep, "filter");
                  return;
               end if;
               Read_Operand (Source, Scan, Value, Valid);
               if Valid and then Skip_Spaces (Source, Scan) <= Source'Last then
                  Valid := False;
               end if;
               if Valid then
                  Keep (Value, Kept);
               end if;
               if not Valid or else Kept = 0 then
                  Refuse (Body_Text, Where);
                  if Where = 0 then
                     return;
                  end if;
               end if;
               Emit ((Op => Op_Capture_Begin, others => <>), Where);
               if Where = 0 then
                  return;
               end if;
               Depth := Depth + 1;
               Frames (Depth) := (Kind => Block_Filter, Start => Target,
                                  Filter_At => Kept, others => <>);
            end;

         elsif Trimmed = "endfilter" then
            if Depth = 0 or else Frames (Depth).Kind /= Block_Filter then
               Fail (E.Template_Unbalanced_Block, "endfilter");
               return;
            end if;
            Emit ((Op => Op_Capture_End, Offset => Frames (Depth).Start,
                   others => <>), Where);
            if Where = 0 then
               return;
            end if;
            if Frames (Depth).Filter_At /= 0 then
               Emit ((Op => Op_Output, Value_At => Frames (Depth).Filter_At,
                      others => <>), Where);
               if Where = 0 then
                  return;
               end if;
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

         elsif Model_Runner.Text.Starts_With (Trimmed, "macro ") then
            --  A macro is its body, jumped over where it is defined and
            --  run from its entry where it is called. Its parameters are
            --  names like any other, bound by the call and given back
            --  afterwards, so a macro that calls itself finds its own.
            Compile_Macro
              (Model_Runner.Text.Trim
                 (Trimmed (Trimmed'First + 6 .. Trimmed'Last)));

         elsif Trimmed = "endmacro" or else Trimmed = "endcall" then
            if Depth = 0
              or else Frames (Depth).Kind
                      /= (if Trimmed = "endmacro" then Block_Macro
                          else Block_Call)
            then
               Fail (E.Template_Unbalanced_Block, Trimmed);
               return;
            end if;
            Emit ((Op => Op_Return, others => <>), Where);
            if Where = 0 then
               return;
            end if;
            Item.Program.all (Frames (Depth).Pending).Target :=
              Item.Program_Used + 1;

            --  A call block ends by making the call it wrapped its body
            --  for, with that body named as what caller() runs.
            if Trimmed = "endcall" then
               Emit ((Op => Op_Set_Caller, Offset => Frames (Depth).Start,
                      others => <>), Where);
               if Where = 0 then
                  return;
               end if;
               Emit ((Op => Op_Output, Value_At => Frames (Depth).Filter_At,
                      others => <>), Where);
               if Where = 0 then
                  return;
               end if;
            end if;
            Depth := Depth - 1;

         elsif Model_Runner.Text.Starts_With (Trimmed, "call ")
           or else Model_Runner.Text.Starts_With (Trimmed, "call(")
         then
            --  {% call m(args) %} ... {% endcall %}: the body becomes a
            --  macro of its own, entered from caller() inside m, and the
            --  call is made once the body has been read.
            declare
               Whole  : constant String :=
                 Model_Runner.Text.Trim
                   (Trimmed (Trimmed'First + 4 .. Trimmed'Last));

               --  {% call(x, y) m(...) %}: the names in the brackets are
               --  the body's parameters, which caller(a, b) binds.
               Params_End : constant Natural :=
                 (if Whole'Length > 0 and then Whole (Whole'First) = '('
                  then Closes_At (Whole, Whole'First) else 0);
               Params : constant String :=
                 (if Params_End = 0 then ""
                  else Whole (Whole'First .. Params_End));
               Source : constant String :=
                 (if Params_End = 0 then Whole
                  else Model_Runner.Text.Trim
                         (Whole (Params_End + 1 .. Whole'Last)));
               Value  : Operand;
               Scan   : Natural := Source'First;
               Valid  : Boolean;
               Kept   : Natural := 0;
            begin
               Read_Operand (Source, Scan, Value, Valid);
               if not Valid or else Skip_Spaces (Source, Scan) <= Source'Last
                 or else Value.Count /= 1
                 or else Value.Terms (1).Kind /= Term_Macro
               then
                  Fail (E.Template_Unsupported_Construct, "call");
                  return;
               end if;
               Keep (Value, Kept);
               if Kept = 0 then
                  return;
               end if;
               Compile_Macro
                 ("__caller" & Model_Runner.Text.Image
                    (Long_Long_Integer (Item.Program_Used))
                  & (if Params = "" then "()" else Params));
               if E.Is_Error (Status) or else Depth = 0 then
                  return;
               end if;
               Frames (Depth).Kind := Block_Call;
               Frames (Depth).Filter_At := Kept;
               Frames (Depth).Start := Item.Macro_Used;
            end;

         elsif Trimmed = "endset" then
            if Depth = 0 or else Frames (Depth).Kind /= Block_Set then
               Fail (E.Template_Unbalanced_Block, "endset");
               return;
            end if;
            Emit ((Op => Op_Capture_End, Offset => Frames (Depth).Start,
                   others => <>), Where);
            if Where = 0 then
               return;
            end if;
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
               if (Scan >= First and then Source (Scan) = ASCII.LF)
                 or else (Scan < First and then First = Source'First)
               then
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
      procedure Mark_Numeric_Names is
         type Number_State is (Unset, Only_Numbers, Mixed);
         States  : array (1 .. Max_Variables) of Number_State :=
           [others => Unset];
         Changed : Boolean := True;

         procedure Note (Slot : Natural; Numeric : Boolean) is
         begin
            if Slot = 0 then
               return;
            end if;
            if not Numeric then
               States (Slot) := Mixed;
            elsif States (Slot) = Unset then
               States (Slot) := Only_Numbers;
            end if;
         end Note;

         --  Whether a term reads a number-only name, plainly.
         function Reads_Number (Value : Term) return Boolean
         is (Value.Kind = Term_Variable
             and then Value.Offset /= 0
             and then Value.Path_Len = 0 and then Value.Tail_Len = 0
             and then not Value.Indexes
             and then Value.Chained = 0 and then Value.Filtered = 0
             and then States (Value.Offset) = Only_Numbers);

         --  Mark the terms of one operand, answering whether any changed.
         function Mark (Value : in out Operand) return Boolean is
            Any : Boolean := False;
         begin
            for Index in 1 .. Value.Count loop
               declare
                  T : Term renames Value.Terms (Index);
               begin
                  if not T.Numeric then
                     if Reads_Number (T) then
                        T.Numeric := True;
                        Any := True;
                     elsif T.Kind = Term_Group and then T.Offset /= 0
                       and then Sums (Item.Operands.all (T.Offset))
                     then
                        T.Numeric := True;
                        Any := True;
                     end if;
                  end if;
               end;
            end loop;
            return Any;
         end Mark;
      begin
         --  Every assignment the program makes, by the instruction that
         --  makes it. Copies are settled after the rest, and repeatedly,
         --  because a copy of a copy is a number only once its source is.
         for Step of Item.Program.all (1 .. Item.Program_Used) loop
            case Step.Op is
               when Op_Set_Value =>
                  Note (Step.Offset, Sums (Item.Operands.all (Step.Value_At)));
               when Op_Range_Begin =>
                  Note (Step.Offset, True);
               when Op_Set_Copy =>
                  null;
               when Op_Set_None | Op_Set_Slice | Op_Set_Message
                  | Op_Capture_End | Op_Call_Begin =>
                  Note (Step.Offset, False);
               when Op_Each_Begin =>
                  Note (Step.Offset, False);
                  Note (Step.Length, False);
               when Op_For_Begin =>
                  if Step.Binds then
                     Note (Item.Message_Slot, False);
                  end if;
               when others =>
                  null;
            end case;
         end loop;
         for M in 1 .. Item.Macro_Used loop
            for P in 1 .. Item.Macros (M).Count loop
               Note (Item.Macros (M).Slots (P), False);
            end loop;
         end loop;
         while Changed loop
            Changed := False;
            for Step of Item.Program.all (1 .. Item.Program_Used) loop
               if Step.Op = Op_Set_Copy and then Step.Offset /= 0
                 and then Step.Target /= 0
               then
                  if States (Step.Target) = Mixed
                    and then States (Step.Offset) /= Mixed
                  then
                     States (Step.Offset) := Mixed;
                     Changed := True;
                  elsif States (Step.Target) = Only_Numbers
                    and then States (Step.Offset) = Unset
                  then
                     States (Step.Offset) := Only_Numbers;
                     Changed := True;
                  end if;
               end if;
            end loop;
         end loop;

         --  Then every term that reads one, until nothing more changes:
         --  a group is a sum once the terms inside it are numbers.
         Changed := True;
         while Changed loop
            Changed := False;
            for Index in 1 .. Item.Operand_Used loop
               if Mark (Item.Operands.all (Index)) then
                  Changed := True;
               end if;
            end loop;
            for Index in 1 .. Item.Condition_Used loop
               for C in 1 .. Item.Conditions.all (Index).Clause_Used loop
                  if Mark (Item.Conditions.all (Index).Clauses (C).Left) then
                     Changed := True;
                  end if;
                  if Mark (Item.Conditions.all (Index).Clauses (C).Right) then
                     Changed := True;
                  end if;
               end loop;
            end loop;
         end loop;
      end Mark_Numeric_Names;

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

         --  True or false, which is what a comparison written as a value
         --  is worth, and what true and false are. Held as Start: one for
         --  true, and in a slot as Offset. Printed as Python prints it,
         --  and read in a condition as the truth it is.
         Value_Boolean,

         --  A whole number, held as its decimal text: what a number
         --  written down, a count, a length, a sum and a number read out
         --  of JSON are worth. Kept apart from text because the language
         --  keeps them apart -- 1 + 1 is 2 and '1' + '1' is '11', and 1
         --  is not equal to '1' -- and a name assigned a number stays one.
         Value_Number,

         --  A mapping or a list, as JSON text in the pool: what a member
         --  of a tool's schema, a call's arguments, a list written out or
         --  a cut into pieces is held as.
         Value_Data,

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

      type Slot_Table is array (1 .. Max_Variables) of Slot;
      Slots : Slot_Table := [others => <>];

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

      --  The bound a refusal names where it is a bound and not a
      --  construct: the elements a filter walks.
      Refused_Limit : Natural := 0;
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

      --  Where each open capture began in the output, so that endset can
      --  take back what was written since.
      Captures      : array (1 .. Max_Depth) of Natural := [others => 0];
      Capture_Depth : Natural := 0;

      --  How many macro calls are in progress, and whether the innermost
      --  has reached its end; which body caller() runs at each depth, and
      --  the one named for the call about to be made.
      Call_Depth : Natural := 0;
      Returned   : Boolean := False;
      Callers    : array (0 .. Max_Depth) of Natural := [others => 0];
      Pending_Caller : Natural := 0;

      --  Whether the step limit has been reached, which the loop reports.
      Exhausted  : Boolean := False;

      --  Whether a break is on its way to the innermost loop's Next
      --  instruction, which leaves the loop instead of going round.
      Breaking   : Boolean := False;

      --  One instruction, at Position. Declared here because a macro call
      --  runs the body from inside the value that asks for it.
      procedure Execute;

      ------------------------------------------------------------------
      --  Values
      ------------------------------------------------------------------

      function Quoted (Value : String) return String;
      procedure Assign_Text
        (Where : Natural; Value : String; Kind : Value_Kind := Value_Text);
      function Number_Of (Text : String) return Long_Long_Integer;
      function Real_Of (Text : String) return Long_Float;
      function Real_Image (X : Long_Float) return String;

      --  Whether a number's text is not a whole number: a point or an
      --  exponent in it. What decides whether a sum is worked out in
      --  whole numbers or in binary64.
      function Is_Real (Text : String) return Boolean
      is (for some C of Text => C in '.' | 'e' | 'E');

      --  What a term is worth before it is text: the value itself, with
      --  its kind. Text and a mapping or list -- JSON, as the tools and a
      --  call's arguments arrive and as a list written out or a cut made
      --  is spelled -- carry their text here; a message, a call and a tool
      --  carry their positions, as a slot does.
      type Held is record
         Kind  : Value_Kind := Value_Undefined;
         Text  : Ada.Strings.Unbounded.Unbounded_String;
         Start : Natural := 0;
         Index : Natural := 0;
      end record;

      function Text_Of (Value : Held) return String
      is (Ada.Strings.Unbounded.To_String (Value.Text));

      function As_Text (Value : String) return Held
      is (Kind => Value_Text,
          Text => Ada.Strings.Unbounded.To_Unbounded_String (Value),
          others => <>);

      function As_Data (Value : String) return Held
      is (Kind => Value_Data,
          Text => Ada.Strings.Unbounded.To_Unbounded_String (Value),
          others => <>);

      --  A number as its canonical text: a whole number as written, and
      --  one that is not written as Python writes it, so that 1.50 and
      --  1.0e15 print as 1.5 and 1000000000000000.0.
      function As_Number (Value : String) return Held
      is (Kind => Value_Number,
          Text => Ada.Strings.Unbounded.To_Unbounded_String
                    (if Is_Real (Value)
                     then Real_Image (Real_Of (Model_Runner.Text.Trim (Value)))
                     else Model_Runner.Text.Trim (Value)),
          others => <>);

      function As_Number (Value : Long_Long_Integer) return Held
      is (As_Number (Model_Runner.Text.Image (Value)));

      Nothing : constant Held := (Kind => Value_Undefined, others => <>);

      --  What a term is worth before its methods and filters, and after.
      --  Defined with the values' filters below, once the text they are
      --  built from is at hand.
      function Base_Of (Value : Term) return Held;
      function Indexed (Value : Held; Key : String) return Held;
      function Resolve (Value : Term) return Held;
      function Is_Sum (Value : Operand) return Boolean;
      function Held_Of (Value : Operand) return Held;
      function Truth_Of (Value : Condition) return Boolean;

      --  The JSON a value is, as text: a mapping or list as it stands, a
      --  tool as the definitions hold it, text as a JSON string, none as
      --  null.
      function Listed (Value : Held) return String;
      function Element_Of_Listed (One : Held) return String;

      function JSON_Text (Value : Held) return String is
      begin
         case Value.Kind is
            when Value_Data => return Text_Of (Value);
            when Value_JSON =>
               return Offered_Tools.Definition (Tools.all, Value.Start);
            when Value_Message => return Element_Of_Listed (Value);
            when Value_List | Value_Tools => return Listed (Value);
            when Value_Call =>
               if Value.Index = 0 then
                  return Listed (Value);
               end if;
               if Value.Start = 0 or else Value.Start > Count
                 or else Value.Index > Conv.Call_Count (Messages, Value.Start)
               then
                  return "null";
               end if;
               return "{""name"": "
                 & Quoted (Conv.Call_Name (Messages, Value.Start, Value.Index))
                 & ", ""arguments"": "
                 & Conv.Call_Arguments (Messages, Value.Start, Value.Index)
                 & "}";
            when Value_Text => return Quoted (Text_Of (Value));
            when Value_Number => return Text_Of (Value);
            when Value_None => return "null";
            when Value_Boolean =>
               return (if Value.Start = 1 then "true" else "false");
            when others => return "";
         end case;
      end JSON_Text;

      --  Reading JSON, over whatever text holds it. A span of it, empty
      --  when First > Last.
      type Span is record
         First : Natural := 1;
         Last  : Natural := 0;
      end record;

      function Past_Blanks (Src : String; From : Natural) return Natural is
         I : Natural := From;
      begin
         while I <= Src'Last
           and then Src (I) in ' ' | ASCII.LF | ASCII.CR | ASCII.HT
         loop
            I := I + 1;
         end loop;
         return I;
      end Past_Blanks;

      --  The value beginning at From: a string with its quotes, an object
      --  or array with its brackets, or a bare number or word.
      function Value_At (Src : String; From : Natural) return Span is
         I : Natural := Past_Blanks (Src, From);
         Depth : Natural := 0;
         In_String : Boolean := False;
         Start : constant Natural := I;
      begin
         if I > Src'Last then
            return (1, 0);
         end if;
         if Src (I) = '"' then
            I := I + 1;
            while I <= Src'Last and then Src (I) /= '"' loop
               if Src (I) = '\' then
                  I := I + 1;
               end if;
               I := I + 1;
            end loop;
            return (Start, Natural'Min (I, Src'Last));
         elsif Src (I) in '{' | '[' then
            loop
               exit when I > Src'Last;
               if In_String then
                  if Src (I) = '\' then
                     I := I + 1;
                  elsif Src (I) = '"' then
                     In_String := False;
                  end if;
               elsif Src (I) = '"' then
                  In_String := True;
               elsif Src (I) in '{' | '[' then
                  Depth := Depth + 1;
               elsif Src (I) in '}' | ']' then
                  Depth := Depth - 1;
                  exit when Depth = 0;
               end if;
               I := I + 1;
            end loop;
            return (Start, Natural'Min (I, Src'Last));
         else
            while I <= Src'Last
              and then Src (I) not in ',' | '}' | ']' | ' ' | ASCII.LF
            loop
               I := I + 1;
            end loop;
            return (Start, I - 1);
         end if;
      end Value_At;

      --  The next member of an object from Cursor, which starts just past
      --  the opening brace; Found is False at the closing one.
      procedure Next_Member
        (Src    : String;
         Cursor : in out Natural;
         Key    : out Span;
         Value  : out Span;
         Found  : out Boolean)
      is
         I : Natural := Past_Blanks (Src, Cursor);
      begin
         Found := False;
         Key := (1, 0);
         Value := (1, 0);
         if I <= Src'Last and then Src (I) = ',' then
            I := Past_Blanks (Src, I + 1);
         end if;
         if I > Src'Last or else Src (I) /= '"' then
            return;
         end if;
         Key := Value_At (Src, I);
         I := Past_Blanks (Src, Key.Last + 1);
         if I <= Src'Last and then Src (I) = ':' then
            I := I + 1;
         end if;
         Value := Value_At (Src, I);
         Cursor := Value.Last + 1;
         Found := True;
      end Next_Member;

      --  The next element of an array from Cursor, just past the bracket.
      procedure Next_Element
        (Src    : String;
         Cursor : in out Natural;
         Value  : out Span;
         Found  : out Boolean)
      is
         I : Natural := Past_Blanks (Src, Cursor);
      begin
         Found := False;
         Value := (1, 0);
         if I <= Src'Last and then Src (I) = ',' then
            I := Past_Blanks (Src, I + 1);
         end if;
         if I > Src'Last or else Src (I) = ']' then
            return;
         end if;
         Value := Value_At (Src, I);
         Cursor := Value.Last + 1;
         Found := True;
      end Next_Element;

      function Is_JSON_String (Src : String) return Boolean
      is (Src'Length > 0 and then Src (Src'First) = '"');
      function Is_JSON_Mapping (Src : String) return Boolean
      is (Src'Length > 0 and then Src (Src'First) = '{');
      function Is_JSON_List (Src : String) return Boolean
      is (Src'Length > 0 and then Src (Src'First) = '[');

      --  A JSON string's characters. The escapes are the ones JSON
      --  requires; a definition's own are decoded already.
      function Decoded (Src : String) return String is
         R : String (1 .. Src'Length);
         M : Natural := 0;
         I : Natural := Src'First + 1;
      begin
         if not Is_JSON_String (Src) then
            return Src;
         end if;
         while I < Src'Last loop
            if Src (I) = '\' and then I + 1 < Src'Last then
               I := I + 1;
               M := M + 1;
               case Src (I) is
                  when 'n' => R (M) := ASCII.LF;
                  when 't' => R (M) := ASCII.HT;
                  when 'r' => R (M) := ASCII.CR;
                  when others => R (M) := Src (I);
               end case;
            else
               M := M + 1;
               R (M) := Src (I);
            end if;
            I := I + 1;
         end loop;
         return R (1 .. M);
      end Decoded;

      --  A member of a mapping by name, or nothing.
      --  A value read out of JSON: a string is text, decoded, so that
      --  what is done to it -- indexed, measured, asked whether it begins
      --  with something -- is done to the text; anything else stays
      --  JSON.
      --  A JSON number, whole or not: digits with a sign, a point and an
      --  exponent where it has them.
      function Is_JSON_Number (Src : String) return Boolean
      is (Src'Length > 0
          and then Src (Src'First) in '0' .. '9' | '-'
          and then Src (Src'Last) in '0' .. '9'
          and then (for all C of Src =>
                      C in '0' .. '9' | '-' | '+' | '.' | 'e' | 'E'));

      function Read_Out (Src : String) return Held
      is (if Is_JSON_String (Src) then As_Text (Decoded (Src))
          elsif Is_JSON_Number (Src) then As_Number (Src)
          elsif Src = "null" then (Kind => Value_None, others => <>)
          elsif Src = "true" then (Kind => Value_Boolean, Start => 1, others => <>)
          elsif Src = "false" then (Kind => Value_Boolean, Start => 0, others => <>)
          else As_Data (Src));

      function Member_Of (Src : String; Name : String) return Held is
         Cursor : Natural;
         Key, Value : Span;
         Found : Boolean;
      begin
         if not Is_JSON_Mapping (Src) then
            return Nothing;
         end if;
         Cursor := Src'First + 1;
         loop
            Next_Member (Src, Cursor, Key, Value, Found);
            exit when not Found;
            if Decoded (Src (Key.First .. Key.Last)) = Name then
               return Read_Out (Src (Value.First .. Value.Last));
            end if;
         end loop;
         return Nothing;
      end Member_Of;

      --  An element of a list by position, counted from zero and from the
      --  end where negative, or nothing.
      function Element_Of (Src : String; Wanted : Long_Long_Integer)
        return Held
      is
         Cursor : Natural;
         Value  : Span;
         Found  : Boolean;
         Total  : Natural := 0;
         Seen   : Long_Long_Integer := 0;
         Target_Index : Long_Long_Integer := Wanted;
      begin
         if not Is_JSON_List (Src) then
            return Nothing;
         end if;
         if Wanted < 0 then
            Cursor := Src'First + 1;
            loop
               Next_Element (Src, Cursor, Value, Found);
               exit when not Found;
               Total := Total + 1;
            end loop;
            Target_Index := Long_Long_Integer (Total) + Wanted;
            if Target_Index < 0 then
               return Nothing;
            end if;
         end if;
         Cursor := Src'First + 1;
         loop
            Next_Element (Src, Cursor, Value, Found);
            exit when not Found;
            if Seen = Target_Index then
               return Read_Out (Src (Value.First .. Value.Last));
            end if;
            Seen := Seen + 1;
         end loop;
         return Nothing;
      end Element_Of;

      --  How many elements a list has, or entries a mapping.
      function JSON_Length (Src : String) return Natural is
         Cursor : Natural;
         Key, Value : Span;
         Found : Boolean;
         Total : Natural := 0;
      begin
         if Is_JSON_List (Src) then
            Cursor := Src'First + 1;
            loop
               Next_Element (Src, Cursor, Value, Found);
               exit when not Found;
               Total := Total + 1;
            end loop;
         elsif Is_JSON_Mapping (Src) then
            Cursor := Src'First + 1;
            loop
               Next_Member (Src, Cursor, Key, Value, Found);
               exit when not Found;
               Total := Total + 1;
            end loop;
         elsif Is_JSON_String (Src) then
            return Decoded (Src)'Length;
         end if;
         return Total;
      end JSON_Length;

      --  Python's str of a JSON value, which is what `| string` and a
      --  printed value are: a string as its characters, true as True,
      --  null as None, and a list or a mapping as its repr, strings in
      --  single quotes.
      function Pythonic (Src : String) return String;

      function Repr (Src : String) return String is
         R : Ada.Strings.Unbounded.Unbounded_String;
         Cursor : Natural;
         Key, Value : Span;
         Found : Boolean;
         First_One : Boolean := True;
      begin
         if Is_JSON_String (Src) then
            return "'" & Decoded (Src) & "'";
         elsif Is_JSON_List (Src) then
            Ada.Strings.Unbounded.Append (R, "[");
            Cursor := Src'First + 1;
            loop
               Next_Element (Src, Cursor, Value, Found);
               exit when not Found;
               if not First_One then
                  Ada.Strings.Unbounded.Append (R, ", ");
               end if;
               First_One := False;
               Ada.Strings.Unbounded.Append
                 (R, Repr (Src (Value.First .. Value.Last)));
            end loop;
            Ada.Strings.Unbounded.Append (R, "]");
            return Ada.Strings.Unbounded.To_String (R);
         elsif Is_JSON_Mapping (Src) then
            Ada.Strings.Unbounded.Append (R, "{");
            Cursor := Src'First + 1;
            loop
               Next_Member (Src, Cursor, Key, Value, Found);
               exit when not Found;
               if not First_One then
                  Ada.Strings.Unbounded.Append (R, ", ");
               end if;
               First_One := False;
               Ada.Strings.Unbounded.Append
                 (R, Repr (Src (Key.First .. Key.Last)) & ": "
                     & Repr (Src (Value.First .. Value.Last)));
            end loop;
            Ada.Strings.Unbounded.Append (R, "}");
            return Ada.Strings.Unbounded.To_String (R);
         end if;
         return Pythonic (Src);
      end Repr;

      function Pythonic (Src : String) return String is
      begin
         if Is_JSON_String (Src) then
            return Decoded (Src);
         elsif Is_JSON_List (Src) or else Is_JSON_Mapping (Src) then
            return Repr (Src);
         elsif Src = "true" then
            return "True";
         elsif Src = "false" then
            return "False";
         elsif Src = "null" then
            return "None";
         end if;
         return Src;
      end Pythonic;

      --  What a value prints as.
      function Printed (Value : Held) return String is
      begin
         case Value.Kind is
            when Value_Text | Value_Number => return Text_Of (Value);
            when Value_Data => return Pythonic (Text_Of (Value));
            when Value_JSON => return JSON_Text (Value);
            when Value_Boolean =>
               return (if Value.Start = 1 then "True" else "False");
            when Value_None => return "None";
            when others => return "";
         end case;
      end Printed;

      --  A slot's value.
      function Held_Of (Where : Natural) return Held is
         Holder : Slot renames Slots (Where);
      begin
         case Holder.Kind is
            when Value_Text =>
               return As_Text
                 (Pool (Holder.Offset + 1 .. Holder.Offset + Holder.Length));
            when Value_Number =>
               return As_Number
                 (Pool (Holder.Offset + 1 .. Holder.Offset + Holder.Length));
            when Value_Data =>
               return As_Data
                 (Pool (Holder.Offset + 1 .. Holder.Offset + Holder.Length));
            when Value_Message =>
               return (Kind => Value_Message, Start => Holder.Start,
                       others => <>);
            when Value_Call =>
               return (Kind => Value_Call, Start => Holder.Offset,
                       Index => Holder.Start, others => <>);
            when Value_JSON =>
               return (Kind => Value_JSON, Start => Holder.Start,
                       others => <>);
            when Value_List =>
               return (Kind => Value_List, Start => Holder.Start,
                       others => <>);
            when Value_Tools =>
               return (Kind => Value_Tools, others => <>);
            when Value_None =>
               return (Kind => Value_None, others => <>);
            when Value_Boolean =>
               return (Kind => Value_Boolean, Start => Holder.Offset,
                       others => <>);
            when Value_Undefined =>
               return Nothing;
         end case;
      end Held_Of;

      --  A message's field, a call's, a tool's or a mapping's member, by
      --  name. A field a message has not got is nothing, which is what a
      --  template's "is defined" is written to find out.
      function Field_Of (Value : Held; Name : String) return Held is
      begin
         case Value.Kind is
            when Value_Message =>
               if Value.Start = 0 or else Value.Start > Count then
                  return Nothing;
               elsif Name = "role" then
                  return As_Text
                    (Conv.Role_Name (Conv.Sender_At (Messages, Value.Start)));
               elsif Name = "content" then
                  return As_Text (Conv.Content_At (Messages, Value.Start));
               elsif Name = "tool_calls" then
                  if Conv.Call_Count (Messages, Value.Start) = 0 then
                     return Nothing;
                  end if;
                  return (Kind => Value_Call, Start => Value.Start,
                          Index => 0, others => <>);
               end if;
               return Nothing;

            when Value_Call =>
               if Value.Index = 0 then
                  return Nothing;
               elsif Name = "name" then
                  return As_Text
                    (Conv.Call_Name (Messages, Value.Start, Value.Index));
               elsif Name = "arguments" then
                  return As_Data
                    (Conv.Call_Arguments (Messages, Value.Start, Value.Index));
               end if;
               return Nothing;

            when Value_JSON | Value_Data =>
               return Member_Of (JSON_Text (Value), Name);

            when others =>
               return Nothing;
         end case;
      end Field_Of;

      --  A path of members read off a value, one name at a time.
      function Along (Value : Held; Path : String) return Held is
         Result : Held := Value;
         From   : Natural := Path'First;
      begin
         while From <= Path'Last loop
            declare
               Dot : Natural := From;
            begin
               while Dot <= Path'Last and then Path (Dot) /= '.' loop
                  Dot := Dot + 1;
               end loop;
               Result := Field_Of (Result, Path (From .. Dot - 1));
               From := Dot + 1;
            end;
         end loop;
         return Result;
      end Along;

      --  An element of a value by position: of a list, of a turn's calls,
      --  of a list of messages.
      function Element_At (Value : Held; Wanted : Long_Long_Integer)
        return Held is
      begin
         case Value.Kind is
            when Value_Data =>
               return Element_Of (Text_Of (Value), Wanted);
            when Value_Text =>
               --  One character of the text, counted from the end when
               --  the position is negative; a position past either end
               --  is nothing, where the language would raise.
               declare
                  Held : constant String := Text_Of (Value);
                  At_Char : constant Long_Long_Integer :=
                    (if Wanted < 0
                     then Long_Long_Integer (Held'Length) + Wanted
                     else Wanted);
               begin
                  if At_Char < 0
                    or else At_Char >= Long_Long_Integer (Held'Length)
                  then
                     return Nothing;
                  end if;
                  return As_Text
                    (Held (Held'First + Natural (At_Char)
                           .. Held'First + Natural (At_Char)));
               end;
            when Value_Call =>
               --  The calls of a turn, indexed: Index zero says the whole
               --  list is meant.
               declare
                  Total : constant Natural :=
                    (if Value.Start = 0 or else Value.Start > Count then 0
                     else Conv.Call_Count (Messages, Value.Start));
                  At_Call : constant Long_Long_Integer :=
                    (if Wanted < 0 then Long_Long_Integer (Total) + Wanted + 1
                     else Wanted + 1);
               begin
                  if Value.Index /= 0 or else At_Call < 1
                    or else At_Call > Long_Long_Integer (Total)
                  then
                     return Nothing;
                  end if;
                  return (Kind => Value_Call, Start => Value.Start,
                          Index => Natural (At_Call), others => <>);
               end;
            when Value_List =>
               declare
                  At_Message : constant Long_Long_Integer :=
                    Long_Long_Integer (Value.Start) + Wanted;
               begin
                  if At_Message < 1 or else At_Message > Long_Long_Integer (Count)
                  then
                     return (Kind => Value_None, others => <>);
                  end if;
                  return (Kind => Value_Message, Start => Natural (At_Message),
                          others => <>);
               end;
            when Value_Tools =>
               if Wanted < 0 or else Wanted >= Long_Long_Integer (Tool_Count)
               then
                  return Nothing;
               end if;
               return (Kind => Value_JSON, Start => Natural (Wanted) + 1,
                       others => <>);
            when others =>
               return Nothing;
         end case;
      end Element_At;

      --  How many things a value holds: a text's characters, a list's
      --  elements, a mapping's entries, the tools, the messages of a list
      --  from where it begins, a turn's calls.
      function Length_Of (Value : Held) return Natural is
      begin
         case Value.Kind is
            when Value_Text => return Text_Of (Value)'Length;
            when Value_Data => return JSON_Length (Text_Of (Value));
            when Value_JSON => return JSON_Length (JSON_Text (Value));
            when Value_Tools => return Tool_Count;
            when Value_List =>
               return Integer'Max (Count - Value.Start + 1, 0);
            when Value_Call =>
               if Value.Index /= 0 or else Value.Start = 0
                 or else Value.Start > Count
               then
                  return 0;
               end if;
               return Conv.Call_Count (Messages, Value.Start);
            when others => return 0;
         end case;
      end Length_Of;

      --  Whether a value holds anything, as a condition asks.
      function Is_Truthy (Value : Held) return Boolean is
      begin
         case Value.Kind is
            when Value_Undefined | Value_None => return False;
            when Value_Boolean => return Value.Start = 1;
            when Value_Number => return Number_Of (Text_Of (Value)) /= 0;
            when Value_Text =>
               declare
                  T : constant String := Text_Of (Value);
               begin
                  return T /= "" and then T /= "false" and then T /= "none"
                    and then T /= "0";
               end;
            when Value_Data =>
               declare
                  T : constant String := Text_Of (Value);
               begin
                  return T /= "[]" and then T /= "{}" and then T /= "false"
                    and then T /= "null" and then T /= "0"
                    and then T /= """""";
               end;
            when Value_Tools => return Tool_Count > 0;
            when Value_List => return Count >= Value.Start;
            when Value_Call => return Length_Of (Value) > 0 or else Value.Index > 0;
            when others => return True;
         end case;
      end Is_Truthy;

      --  Give a name a value, keeping its kind: text and JSON into the
      --  pool, positions as they are.
      procedure Assign_Data (Where : Natural; Value : String);

      procedure Store (Where : Natural; Value : Held) is
      begin
         case Value.Kind is
            when Value_Text => Assign_Text (Where, Text_Of (Value));
            when Value_Number =>
               Assign_Text (Where, Text_Of (Value), Value_Number);
            when Value_Data => Assign_Data (Where, Text_Of (Value));
            when Value_Message =>
               Slots (Where) := (Kind => Value_Message, Offset => 0,
                                 Length => 0, Start => Value.Start);
            when Value_Call =>
               Slots (Where) := (Kind => Value_Call, Offset => Value.Start,
                                 Length => 0, Start => Value.Index);
            when Value_JSON =>
               Slots (Where) := (Kind => Value_JSON, Start => Value.Start,
                                 others => <>);
            when Value_List =>
               Slots (Where) := (Kind => Value_List, Start => Value.Start,
                                 others => <>);
            when Value_Tools =>
               Slots (Where) := (Kind => Value_Tools, others => <>);
            when Value_None =>
               Slots (Where) := (Kind => Value_None, others => <>);
            when Value_Boolean =>
               Slots (Where) := (Kind => Value_Boolean, Offset => Value.Start,
                                 others => <>);
            when Value_Undefined =>
               Slots (Where) := (Kind => Value_Undefined, others => <>);
         end case;
      end Store;

      ------------------------------------------------------------------
      --  Loops, of every kind, on one stack
      ------------------------------------------------------------------

      --  What a running loop walks and where it has got to, so that
      --  loop.first and its kin answer for the innermost loop whatever
      --  kind it is, and so that loops nest -- one over a mapping's
      --  entries inside one over a list inside one over the tools, which
      --  is what a template that writes a schema out does. The legacy
      --  kinds keep their state where they always did and are here only
      --  so that the stack knows which loop is innermost.
      type Loop_Kind is
        (Over_Elements,   --  a JSON list, element by element
         Over_Entries,    --  a JSON mapping, entry by entry
         Over_Tools,      --  the tools offered
         Over_Messages,   --  a list of messages
         Over_Calls,      --  a turn's calls
         Legacy_List, Legacy_Calls, Legacy_Range,

         --  Not a loop: a macro call, on the same stack because it scopes
         --  names the same way -- what the body assigns is the body's own
         --  and is put back when it returns, a namespace's field aside --
         --  and so that loop.index inside a macro is not the caller's.
         Macro_Call);

      type Loop_State is record
         Kind    : Loop_Kind := Legacy_List;
         Var     : Natural := 0;   --  the slot each element goes to
         Key     : Natural := 0;   --  and the entry's key, for a mapping
         Base    : Natural := 0;   --  the container's text in the pool
         Base_Length : Natural := 0;
         Cursor  : Natural := 0;   --  where the next element is read from
         Index   : Natural := 0;   --  one for the first element
         Total   : Natural := 0;
         Message : Natural := 0;   --  the turn a calls loop walks
         From, To : Natural := 0;  --  a message list's ends
         Reversed : Boolean := False;

         --  What every name held when the loop began, and how much of the
         --  pool was in use. A name assigned inside a loop's body is the
         --  body's own -- the language scopes it so, and a template that
         --  builds a value in a loop and reads it after is reading what
         --  the name held before -- so the names are put back when the
         --  loop ends. A namespace's field is the one thing that outlives
         --  the loop, which is what namespaces are for.
         Saved : Slot_Table := [others => <>];
         Floor : Natural := 0;
      end record;

      Max_Loops : constant := 4 * Max_Depth;
      Loops     : array (1 .. Max_Loops) of Loop_State;
      Loop_Depth : Natural := 0;

      procedure Push_Loop (State : Loop_State) is
      begin
         if Loop_Depth < Max_Loops then
            Loop_Depth := Loop_Depth + 1;
            Loops (Loop_Depth) := State;
            Loops (Loop_Depth).Saved := Slots;
            Loops (Loop_Depth).Floor := Pool_Used;
         end if;
      end Push_Loop;

      --  The pool below the innermost loop's floor is what names held
      --  before it began, and is kept as it was until the loop ends.
      function Floor_Now return Natural
      is (if Loop_Depth > 0 then Loops (Loop_Depth).Floor else 0);

      --  Whether a name is a namespace's field, which is spelled with a
      --  dot and is the one kind of name a loop's body assigns for after.
      function Is_Namespace_Slot (Where : Positive) return Boolean
      is (for some Letter of
            Item.Source.all (Item.Names (Where).Offset + 1
                             .. Item.Names (Where).Offset
                                + Item.Names (Where).Length)
          => Letter = '.');

      procedure Pop_Loop is
      begin
         if Loop_Depth = 0 then
            return;
         end if;

         declare
            L : Loop_State renames Loops (Loop_Depth);
            Kept_Above : Boolean := False;
         begin
            for Index in 1 .. Item.Name_Used loop
               if not Is_Namespace_Slot (Index) then
                  Slots (Index) := L.Saved (Index);
               end if;
               if Slots (Index).Kind in Value_Text | Value_Data | Value_Number
                 and then Slots (Index).Offset + Slots (Index).Length
                          > L.Floor
               then
                  Kept_Above := True;
               end if;
            end loop;

            --  The room the body used is free again unless something that
            --  outlives the loop was put there.
            if not Kept_Above and then Pool_Used > L.Floor then
               Pool_Used := L.Floor;
            end if;
         end;
         Loop_Depth := Loop_Depth - 1;
      end Pop_Loop;

      --  Whether the innermost loop is one of the new kinds, whose state
      --  is on the stack rather than in the legacy variables.
      function Innermost_Is_New return Boolean
      is (Loop_Depth > 0
          and then Loops (Loop_Depth).Kind in Over_Elements .. Over_Calls);

      --  Give a name a text value, taking back the room the name last held
      --  where that room is the newest in the pool. Written once because
      --  three instructions do it and one of them does it every time round
      --  a loop.
      procedure Assign_Text
        (Where : Natural; Value : String; Kind : Value_Kind := Value_Text)
      is
         Held : Slot renames Slots (Where);
      begin
         --  A name reassigned in a loop -- which is how a template builds
         --  one message's text before emitting it -- is almost always the
         --  newest thing in the pool. Taking its room back makes that loop
         --  cost what one iteration costs instead of what all of them do.
         --  Value is already a copy, so the old text may go.
         if Held.Kind in Value_Text | Value_Data | Value_Number
           and then Held.Offset + Held.Length = Pool_Used
           and then Held.Offset >= Floor_Now
         then
            Pool_Used := Held.Offset;
         end if;

         if Pool_Used + Value'Length > Pool'Length then
            Refuse (Item.Names (Where).Offset, Item.Names (Where).Length,
                    E.Template_Variables_Too_Large);
         else
            Pool (Pool_Used + 1 .. Pool_Used + Value'Length) := Value;
            Slots (Where) :=
              (Kind => Kind, Offset => Pool_Used,
               Length => Value'Length, Start => 1);
            Pool_Used := Pool_Used + Value'Length;
         end if;
      end Assign_Text;

      --  The same for a mapping or a list, which lives in the pool as its
      --  JSON and is told from text by its kind.
      procedure Assign_Data (Where : Natural; Value : String) is
         Held : Slot renames Slots (Where);
      begin
         if Held.Kind in Value_Text | Value_Data | Value_Number
           and then Held.Offset + Held.Length = Pool_Used
           and then Held.Offset >= Floor_Now
         then
            Pool_Used := Held.Offset;
         end if;

         if Pool_Used + Value'Length > Pool'Length then
            Refuse (Item.Names (Where).Offset, Item.Names (Where).Length,
                    E.Template_Variables_Too_Large);
         else
            Pool (Pool_Used + 1 .. Pool_Used + Value'Length) := Value;
            Slots (Where) :=
              (Kind => Value_Data, Offset => Pool_Used,
               Length => Value'Length, Start => 1);
            Pool_Used := Pool_Used + Value'Length;
         end if;
      end Assign_Data;

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

      --  Where a counting loop has got to, where it stops and what it steps
      --  by, and which name it writes each number to.
      --
      --  One set of these rather than one a depth: a counting loop inside
      --  another counting loop is refused where it is compiled, so there is
      --  never more than one running.
      Range_At    : Long_Long_Integer := 0;
      Range_Start : Long_Long_Integer := 0;
      Range_Stop  : Long_Long_Integer := 0;
      Range_Step  : Long_Long_Integer := 1;
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

      --  Whether what is being evaluated is a condition rather than output.
      --  A condition may ask about a name the template never assigned; the
      --  output may not, and the difference is which of the two is running.
      Testing : Boolean := False;

      --  Value of one term in the current context, before its filter.
      --  The moment of rendering, written as a strftime format says. The
      --  directives are the ones the templates use to write a date into a
      --  system prompt -- day, month and year in numbers and in English
      --  names, the time, the weekday -- and one this engine has no
      --  answer for refuses where it is read rather than writing the
      --  letter. Local time, which is what the language's strftime writes.
      function Now_As (Format : String; Value : Term) return String is
         package Fmt renames Ada.Calendar.Formatting;

         Now    : constant Ada.Calendar.Time := Ada.Calendar.Clock;
         Zone   : constant Ada.Calendar.Time_Zones.Time_Offset :=
           Ada.Calendar.Time_Zones.UTC_Time_Offset (Now);
         Year   : constant Ada.Calendar.Year_Number := Fmt.Year (Now, Zone);
         Month  : constant Ada.Calendar.Month_Number := Fmt.Month (Now, Zone);
         Day    : constant Ada.Calendar.Day_Number := Fmt.Day (Now, Zone);
         Hour   : constant Fmt.Hour_Number := Fmt.Hour (Now, Zone);
         Minute : constant Fmt.Minute_Number := Fmt.Minute (Now, Zone);
         Second : constant Fmt.Second_Number := Fmt.Second (Now);
         Week   : constant Fmt.Day_Name := Fmt.Day_Of_Week (Now);

         Months : constant array (Ada.Calendar.Month_Number) of String (1 .. 9)
           := ["January  ", "February ", "March    ", "April    ",
               "May      ", "June     ", "July     ", "August   ",
               "September", "October  ", "November ", "December "];
         Days   : constant array (Fmt.Day_Name) of String (1 .. 9)
           := ["Monday   ", "Tuesday  ", "Wednesday", "Thursday ",
               "Friday   ", "Saturday ", "Sunday   "];

         --  The day's number in the year, counted from one.
         function Day_Of_Year return Natural is
            Lengths : constant array (Ada.Calendar.Month_Number) of Natural :=
              [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
            Leap    : constant Boolean :=
              (Year mod 4 = 0 and then Year mod 100 /= 0)
              or else Year mod 400 = 0;
            Total   : Natural := Day;
         begin
            for M in 1 .. Month - 1 loop
               Total := Total + Lengths (M)
                 + (if M = 2 and then Leap then 1 else 0);
            end loop;
            return Total;
         end Day_Of_Year;

         function Two (Number : Natural) return String
         is ((if Number < 10 then "0" else "")
             & Model_Runner.Text.Image (Long_Long_Integer (Number)));

         function Plain (Number : Natural) return String
         is (Model_Runner.Text.Image (Long_Long_Integer (Number)));

         Result : Ada.Strings.Unbounded.Unbounded_String;
         Index  : Natural := Format'First;
      begin
         while Index <= Format'Last loop
            if Format (Index) /= '%' or else Index = Format'Last then
               Ada.Strings.Unbounded.Append (Result, Format (Index));
               Index := Index + 1;
            else
               declare
                  --  A dash before the letter drops the leading zero, as
                  --  the C library's strftime reads it.
                  Bare   : constant Boolean := Format (Index + 1) = '-';
                  Letter : constant Character :=
                    (if Bare and then Index + 2 <= Format'Last
                     then Format (Index + 2)
                     else Format (Index + 1));

                  function Number (Value : Natural) return String
                  is (if Bare then Plain (Value) else Two (Value));

                  Piece : constant String :=
                    (case Letter is
                        when 'Y' => Plain (Year),
                        when 'y' => Two (Year mod 100),
                        when 'm' => Number (Month),
                        when 'd' => Number (Day),
                        when 'e' => (if Day < 10 then " " else "")
                                    & Plain (Day),
                        when 'H' => Number (Hour),
                        when 'I' => Number ((if Hour mod 12 = 0 then 12
                                             else Hour mod 12)),
                        when 'M' => Number (Minute),
                        when 'S' => Number (Second),
                        when 'p' => (if Hour < 12 then "AM" else "PM"),
                        when 'b' => Months (Month) (1 .. 3),
                        when 'B' => Model_Runner.Text.Trim (Months (Month)),
                        when 'a' => Days (Week) (1 .. 3),
                        when 'A' => Model_Runner.Text.Trim (Days (Week)),
                        when 'j' => Plain (Day_Of_Year),
                        when '%' => "%",
                        when others => "");
               begin
                  if Piece'Length = 0 and then Letter /= '%' then
                     Refuse (Value.Offset, Value.Length,
                             E.Template_Unsupported_Construct);
                     return "";
                  end if;
                  Ada.Strings.Unbounded.Append (Result, Piece);
                  Index := Index + (if Bare then 3 else 2);
               end;
            end if;
         end loop;
         return Ada.Strings.Unbounded.To_String (Result);
      end Now_As;

      --  A macro's body run from its entry to its return, and what it
      --  wrote: the output past the mark where the call began, taken back
      --  off the output and handed to the term. The arguments are read
      --  before the parameters are bound, because a macro that calls
      --  itself names its own parameters in the call; the parameters are
      --  bound fresh and given back afterwards, which is what makes the
      --  recursion a recursion rather than a loop over one set of names.
      function Run_Macro (Value : Term) return String is
         --  caller() is the body the call block in force wrapped up.
         Which  : constant Natural :=
           (if Value.Offset /= 0 then Value.Offset
            else Callers (Call_Depth));
         Mark   : constant Natural := Last;
         Resume : constant Natural := Position;
         Given  : array (1 .. Max_Parameters) of Held;
      begin
         if Which = 0 then
            Refuse (0, 0, E.Template_Unsupported_Construct);
            return "";
         end if;
         declare
            M : Macro renames Item.Macros (Which);
         begin
            if Call_Depth >= Max_Depth or else Loop_Depth >= Max_Loops then
               Refuse (M.Name.Offset, M.Name.Length, E.Template_Nesting_Too_Deep);
               return "";
            end if;

            --  What the arguments are worth, kinds and all: a list read out
            --  of a schema arrives as a list, and a parameter the call leaves
            --  out with no default is nothing, which "is defined" answers.
            for P in 1 .. M.Count loop
               if P <= Value.Length then
                  Given (P) :=
                    Held_Of (Item.Operands.all (Value.Index_At + P - 1));
               elsif M.Defaults (P) /= 0 then
                  Given (P) := Held_Of (Item.Operands.all (M.Defaults (P)));
               else
                  Given (P) := Nothing;
               end if;
            end loop;

            --  The body's names are its own: what it assigns, its parameters
            --  included, is put back when it returns, as a loop's are.
            Push_Loop ((Kind => Macro_Call, others => <>));
            for P in 1 .. M.Count loop
               Slots (M.Slots (P)) := (Kind => Value_Undefined, others => <>);
               Store (M.Slots (P), Given (P));
            end loop;

            Call_Depth := Call_Depth + 1;
            Callers (Call_Depth) := Pending_Caller;
            Pending_Caller := 0;
            Position := M.Entry_At;
            Returned := False;
            while not Returned and then Position <= Item.Program_Used
              and then not Refused and then not Overflow and then not Exhausted
            loop
               Execute;
            end loop;
            Call_Depth := Call_Depth - 1;
            Returned := False;

            Pop_Loop;
            Position := Resume;

            declare
               Written : constant String :=
                 Target (Target'First + Mark .. Target'First + Last - 1);
            begin
               Last := Mark;
               return Written;
            end;
         end;
      end Run_Macro;

      --  How long the innermost loop is and where it is, one-based, for
      --  loop.length and loop.revindex: from the stack for the loops that
      --  keep their state there, and from the legacy variables otherwise.
      function Loop_Index return Long_Long_Integer is
      begin
         if Innermost_Is_New then
            return Long_Long_Integer (Loops (Loop_Depth).Index);
         elsif In_Calls then
            return Long_Long_Integer (Call_At);
         elsif Loop_Depth > 0 and then Loops (Loop_Depth).Kind = Legacy_Range
         then
            return (if Range_Step = 0 then 1
                    else (Range_At - Range_Start) / Range_Step + 1);
         end if;
         return Long_Long_Integer (Current) - Long_Long_Integer (Loop_Start) + 1;
      end Loop_Index;

      function Loop_Total return Natural is
      begin
         if Innermost_Is_New then
            return Loops (Loop_Depth).Total;
         elsif In_Calls then
            return Walking_Count;
         elsif Loop_Depth > 0 and then Loops (Loop_Depth).Kind = Legacy_Range
         then
            if Range_Step = 0 then
               return 1;
            end if;
            declare
               Span : constant Long_Long_Integer :=
                 (if Range_Step > 0 then Range_Stop - Range_Start
                  else Range_Start - Range_Stop);
               Each : constant Long_Long_Integer := abs Range_Step;
            begin
               return (if Span <= 0 then 0
                       else Natural ((Span + Each - 1) / Each));
            end;
         end if;
         return Natural'Max (Count - Loop_Start + 1, 0);
      end Loop_Total;

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
               if Innermost_Is_New then
                  return (if Loops (Loop_Depth).Index = 1 then "true" else "");
               elsif In_Calls then
                  return (if Call_At = 1 then "true" else "");
               end if;
               return (if Current = Loop_Start then "true" else "");
            when Term_Loop_Last =>
               if Innermost_Is_New then
                  return (if Loops (Loop_Depth).Index = Loops (Loop_Depth).Total
                          then "true" else "");
               elsif In_Calls then
                  return (if Call_At = Walking_Count then "true" else "");
               end if;
               return (if Current = Count and then Count > 0 then "true" else "");
            when Term_Loop_Index_Zero =>
               if Innermost_Is_New then
                  return Model_Runner.Text.Image
                    (Long_Long_Integer (Loops (Loop_Depth).Index) - 1);
               elsif In_Calls then
                  return Model_Runner.Text.Image
                    (Long_Long_Integer (Call_At) - 1);
               end if;
               return Model_Runner.Text.Image
                 (Long_Long_Integer (Current) - Long_Long_Integer (Loop_Start));
            when Term_Loop_Length =>
               return Model_Runner.Text.Image (Long_Long_Integer (Loop_Total));
            when Term_Loop_Rev_Index_Zero =>
               return Model_Runner.Text.Image
                 (Long_Long_Integer (Loop_Total) - Loop_Index);
            when Term_Loop_Rev_Index_One =>
               return Model_Runner.Text.Image
                 (Long_Long_Integer (Loop_Total) - Loop_Index + 1);
            when Term_Loop_Index_One =>
               if Innermost_Is_New then
                  return Model_Runner.Text.Image
                    (Long_Long_Integer (Loops (Loop_Depth).Index));
               elsif In_Calls then
                  return Model_Runner.Text.Image (Long_Long_Integer (Call_At));
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
                     when Value_Text | Value_Number =>
                        return Pool (Holder.Offset + 1
                                     .. Holder.Offset + Holder.Length);
                     when Value_Data =>
                        return Pythonic
                          (Pool (Holder.Offset + 1
                                 .. Holder.Offset + Holder.Length));
                     when Value_None =>
                        return "";
                     when Value_Boolean =>
                        return (if Holder.Offset = 1 then "true" else "");
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
            when Term_Now =>
               return Now_As
                 (Item.Source.all
                    (Value.Offset + 1 .. Value.Offset + Value.Length),
                  Value);

            when Term_Raise =>
               --  The template's author refusing this conversation, in
               --  their words. Not a construct this engine lacks: the
               --  message is the diagnostic.
               Refuse (Value.Offset, Value.Length, E.Template_Refused);
               return "";

            when Term_Group =>
               return Value_Of (Item.Operands.all (Value.Offset));

            when Term_Macro =>
               return Run_Macro (Value);

            when Term_List | Term_Dict | Term_Loop_Previous | Term_Loop_Next
               | Term_Condition | Term_Choice | Term_Or | Term_And =>
               return Printed (Base_Of (Value));

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
            when Method_None | Method_Starts_With | Method_Ends_With
               | Method_Replace | Method_Items | Method_Index
               | Method_Member | Method_Keys | Method_Values | Method_Get
               | Method_Upper | Method_Lower | Method_Title
               | Method_Capitalize =>
               --  These are answered on values, in Method_On.
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

            when Method_Cut_From | Method_Cut_To =>
               declare
                  Length : constant Long_Long_Integer :=
                    Long_Long_Integer (Held'Length);
                  Cut    : Long_Long_Integer := Number_Of (Argument);
               begin
                  if Cut < 0 then
                     Cut := Length + Cut;
                  end if;
                  Cut := Long_Long_Integer'Max
                    (0, Long_Long_Integer'Min (Cut, Length));

                  if Step.Kind = Method_Cut_From then
                     return Held (Held'First + Natural (Cut) .. Held'Last);
                  else
                     return Held (Held'First .. Held'First + Natural (Cut) - 1);
                  end if;
               end;

            when Method_Split_Whole =>
               --  A cut nothing said the side of. The list it answers with
               --  has no spelling here, and printing one end of it because
               --  that is the end this engine could give would be a guess.
               Refuse (0, 0, E.Template_Unsupported_Construct);
               return "";

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

      --  A call's arguments -- a JSON object -- written as MiniCPM's
      --  parameter elements. The value the term holds is that object as text;
      --  this reads its top-level pairs and writes a <param name="k">v</param>
      --  for each, the value plain (a JSON string unquoted) and inside a
      --  <![CDATA[..]]> block when it holds a '<', an '&' or a newline.
      function Params_Of (Src : String; Qwen : Boolean := False) return String is
         Buf : String (1 .. 8 * Src'Length + 256);
         N   : Natural := 0;
         I   : Natural := Src'First;

         procedure Put (S : String) is
         begin
            if N + S'Length <= Buf'Length then
               Buf (N + 1 .. N + S'Length) := S;
               N := N + S'Length;
            end if;
         end Put;

         procedure Skip_Blanks is
         begin
            while I <= Src'Last
              and then Src (I) in ' ' | ASCII.LF | ASCII.CR | ASCII.HT
            loop
               I := I + 1;
            end loop;
         end Skip_Blanks;

         --  A JSON string at I ("...") decoded to its characters, I left past
         --  the closing quote.
         function Read_String return String is
            R : String (1 .. Src'Length);
            M : Natural := 0;
         begin
            I := I + 1;
            while I <= Src'Last and then Src (I) /= '"' loop
               if Src (I) = '\' and then I < Src'Last then
                  I := I + 1;
                  M := M + 1;
                  case Src (I) is
                     when 'n'    => R (M) := ASCII.LF;
                     when 't'    => R (M) := ASCII.HT;
                     when 'r'    => R (M) := ASCII.CR;
                     when others => R (M) := Src (I);
                  end case;
               else
                  M := M + 1;
                  R (M) := Src (I);
               end if;
               I := I + 1;
            end loop;
            if I <= Src'Last then
               I := I + 1;
            end if;
            return R (1 .. M);
         end Read_String;

         --  A bare JSON value at I (number, true/false/null, object, array)
         --  as its own text, I left at the following ',' or '}'.
         function Read_Bare return String is
            First : constant Natural := I;
            Depth : Natural := 0;
         begin
            while I <= Src'Last loop
               case Src (I) is
                  when '{' | '[' => Depth := Depth + 1;
                  when '}' | ']' =>
                     exit when Depth = 0;
                     Depth := Depth - 1;
                  when ',' => exit when Depth = 0;
                  when others => null;
               end case;
               I := I + 1;
            end loop;
            return Model_Runner.Text.Trim (Src (First .. I - 1));
         end Read_Bare;
      begin
         Skip_Blanks;
         if I <= Src'Last and then Src (I) = '{' then
            I := I + 1;
         end if;
         loop
            Skip_Blanks;
            exit when I > Src'Last or else Src (I) = '}' or else Src (I) /= '"';
            declare
               Key : constant String := Read_String;
            begin
               Skip_Blanks;
               if I <= Src'Last and then Src (I) = ':' then
                  I := I + 1;
               end if;
               Skip_Blanks;
               declare
                  Quoted_One : constant Boolean :=
                    I <= Src'Last and then Src (I) = '"';
                  Raw : constant String :=
                    (if Quoted_One then Read_String else Read_Bare);

                  --  A value that is not a string is written as both
                  --  templates write it, printed by the language they are
                  --  written in: true as True, null as None.
                  Val : constant String :=
                    (if Quoted_One then Raw
                     elsif Raw = "true" then "True"
                     elsif Raw = "false" then "False"
                     elsif Raw = "null" then "None"
                     else Raw);
                  CDATA : constant Boolean :=
                    Quoted_One
                    and then (for some C of Val =>
                                C = '<' or else C = '&' or else C = ASCII.LF);
               begin
                  if Qwen then
                     --  Qwen3-Coder: <parameter=k>, the value on its own
                     --  line, then </parameter>, no CDATA.
                     Put ("<parameter=");
                     Put (Key);
                     Put (">" & ASCII.LF);
                     Put (Val);
                     Put (ASCII.LF & "</parameter>" & ASCII.LF);
                  else
                     --  MiniCPM: <param name="k">v</param>, a string that
                     --  holds a '<', an '&' or a line break in a CDATA
                     --  block; a value that is not a string is never
                     --  wrapped, because its template asks "is string"
                     --  before it asks what is in it.
                     Put ("<param name=""");
                     Put (Key);
                     Put (""">");
                     if CDATA then
                        Put ("<![CDATA[");
                        Put (Val);
                        Put ("]]>");
                     else
                        Put (Val);
                     end if;
                     Put ("</param>");
                  end if;
               end;
            end;
            Skip_Blanks;
            if I <= Src'Last and then Src (I) = ',' then
               I := I + 1;
            end if;
         end loop;
         return Buf (1 .. N);
      end Params_Of;

      --  What Qwen3-Coder's own template makes of one tool: the walk its
      --  render_item_list macro and its two mapping loops make over the
      --  definition's JSON, written out in Ada over the same text. The JSON
      --  is the definition as the tools package spells it -- one line, a
      --  space after each colon and comma, escapes decoded -- which is the
      --  spelling `| tojson` gives, so a nested mapping is copied as it
      --  stands. Where that template writes a value with `| string` it is
      --  Python's str of it: a number as itself, true as True, null as
      --  None, a list as its repr with single quotes.
      function Qwen_Tool_Of (Src : String) return String is
         Out_Text : Ada.Strings.Unbounded.Unbounded_String;

         procedure Put (S : String) is
         begin
            Ada.Strings.Unbounded.Append (Out_Text, S);
         end Put;

         --  A span of Src, empty when First > Last.
         type Span is record
            First : Natural := 1;
            Last  : Natural := 0;
         end record;

         function Present (S : Span) return Boolean is (S.First <= S.Last);

         function Past_Blanks (From : Natural) return Natural is
            I : Natural := From;
         begin
            while I <= Src'Last
              and then Src (I) in ' ' | ASCII.LF | ASCII.CR | ASCII.HT
            loop
               I := I + 1;
            end loop;
            return I;
         end Past_Blanks;

         --  The value beginning at I: a string with its quotes, an object
         --  or array with its brackets, or a bare number or word.
         function Value_At (From : Natural) return Span is
            I : Natural := Past_Blanks (From);
            Depth : Natural := 0;
            In_String : Boolean := False;
            Start : constant Natural := I;
         begin
            if I > Src'Last then
               return (1, 0);
            end if;
            if Src (I) = '"' then
               I := I + 1;
               while I <= Src'Last and then Src (I) /= '"' loop
                  if Src (I) = '\' then
                     I := I + 1;
                  end if;
                  I := I + 1;
               end loop;
               return (Start, Natural'Min (I, Src'Last));
            elsif Src (I) in '{' | '[' then
               loop
                  exit when I > Src'Last;
                  if In_String then
                     if Src (I) = '\' then
                        I := I + 1;
                     elsif Src (I) = '"' then
                        In_String := False;
                     end if;
                  elsif Src (I) = '"' then
                     In_String := True;
                  elsif Src (I) in '{' | '[' then
                     Depth := Depth + 1;
                  elsif Src (I) in '}' | ']' then
                     Depth := Depth - 1;
                     exit when Depth = 0;
                  end if;
                  I := I + 1;
               end loop;
               return (Start, Natural'Min (I, Src'Last));
            else
               while I <= Src'Last
                 and then Src (I) not in ',' | '}' | ']' | ' ' | ASCII.LF
               loop
                  I := I + 1;
               end loop;
               return (Start, I - 1);
            end if;
         end Value_At;

         --  The next member of an object from Cursor, which starts just
         --  past the opening brace; Found is False at the closing one.
         procedure Next_Member
           (Cursor : in out Natural;
            Key    : out Span;
            Held   : out Span;
            Found  : out Boolean)
         is
            I : Natural := Past_Blanks (Cursor);
         begin
            Found := False;
            Key := (1, 0);
            Held := (1, 0);
            if I <= Src'Last and then Src (I) = ',' then
               I := Past_Blanks (I + 1);
            end if;
            if I > Src'Last or else Src (I) /= '"' then
               return;
            end if;
            Key := Value_At (I);
            I := Past_Blanks (Key.Last + 1);
            if I <= Src'Last and then Src (I) = ':' then
               I := I + 1;
            end if;
            Held := Value_At (I);
            Cursor := Held.Last + 1;
            Found := True;
         end Next_Member;

         --  The next element of an array from Cursor, just past the bracket.
         procedure Next_Element
           (Cursor : in out Natural; Held : out Span; Found : out Boolean)
         is
            I : Natural := Past_Blanks (Cursor);
         begin
            Found := False;
            Held := (1, 0);
            if I <= Src'Last and then Src (I) = ',' then
               I := Past_Blanks (I + 1);
            end if;
            if I > Src'Last or else Src (I) = ']' then
               return;
            end if;
            Held := Value_At (I);
            Cursor := Held.Last + 1;
            Found := True;
         end Next_Element;

         function Member (Obj : Span; Name : String) return Span is
            Cursor : Natural;
            Key, Held : Span;
            Found : Boolean;
         begin
            if not Present (Obj) or else Src (Obj.First) /= '{' then
               return (1, 0);
            end if;
            Cursor := Obj.First + 1;
            loop
               Next_Member (Cursor, Key, Held, Found);
               exit when not Found;
               if Src (Key.First + 1 .. Key.Last - 1) = Name then
                  return Held;
               end if;
            end loop;
            return (1, 0);
         end Member;

         function Is_String (S : Span) return Boolean
         is (Present (S) and then Src (S.First) = '"');
         function Is_Mapping (S : Span) return Boolean
         is (Present (S) and then Src (S.First) = '{');
         function Is_List (S : Span) return Boolean
         is (Present (S) and then Src (S.First) = '[');

         --  A JSON string's characters. The definition's escapes are
         --  decoded already, so what remains are the ones JSON requires.
         function Decoded (S : Span) return String is
            R : String (1 .. S.Last - S.First + 1);
            M : Natural := 0;
            I : Natural := S.First + 1;
         begin
            while I < S.Last loop
               if Src (I) = '\' and then I + 1 < S.Last then
                  I := I + 1;
                  M := M + 1;
                  case Src (I) is
                     when 'n' => R (M) := ASCII.LF;
                     when 't' => R (M) := ASCII.HT;
                     when 'r' => R (M) := ASCII.CR;
                     when others => R (M) := Src (I);
                  end case;
               else
                  M := M + 1;
                  R (M) := Src (I);
               end if;
               I := I + 1;
            end loop;
            return R (1 .. M);
         end Decoded;

         --  Python's str of a value, which is what `| string` writes.
         function Pythonic (S : Span) return String;

         --  Python's repr of a value, which is how str writes a list's or a
         --  mapping's entries: strings in single quotes.
         function Repr (S : Span) return String is
            R : Ada.Strings.Unbounded.Unbounded_String;
            Cursor : Natural;
            Key, Held : Span;
            Found : Boolean;
            First_One : Boolean := True;
         begin
            if Is_String (S) then
               return "'" & Decoded (S) & "'";
            elsif Is_List (S) then
               Ada.Strings.Unbounded.Append (R, "[");
               Cursor := S.First + 1;
               loop
                  Next_Element (Cursor, Held, Found);
                  exit when not Found;
                  if not First_One then
                     Ada.Strings.Unbounded.Append (R, ", ");
                  end if;
                  First_One := False;
                  Ada.Strings.Unbounded.Append (R, Repr (Held));
               end loop;
               Ada.Strings.Unbounded.Append (R, "]");
               return Ada.Strings.Unbounded.To_String (R);
            elsif Is_Mapping (S) then
               Ada.Strings.Unbounded.Append (R, "{");
               Cursor := S.First + 1;
               loop
                  Next_Member (Cursor, Key, Held, Found);
                  exit when not Found;
                  if not First_One then
                     Ada.Strings.Unbounded.Append (R, ", ");
                  end if;
                  First_One := False;
                  Ada.Strings.Unbounded.Append
                    (R, Repr (Key) & ": " & Repr (Held));
               end loop;
               Ada.Strings.Unbounded.Append (R, "}");
               return Ada.Strings.Unbounded.To_String (R);
            end if;
            return Pythonic (S);
         end Repr;

         function Pythonic (S : Span) return String is
            Bare : constant String :=
              (if Present (S) then Src (S.First .. S.Last) else "");
         begin
            if Is_String (S) then
               return Decoded (S);
            elsif Is_List (S) or else Is_Mapping (S) then
               return Repr (S);
            elsif Bare = "true" then
               return "True";
            elsif Bare = "false" then
               return "False";
            elsif Bare = "null" then
               return "None";
            end if;
            return Bare;
         end Pythonic;

         --  render_item_list: a non-empty list inside a tag, its strings
         --  in backticks and anything else as it prints.
         procedure Item_List (List : Span; Tag : String) is
            Cursor : Natural;
            Held : Span;
            Found : Boolean;
            First_One : Boolean := True;
         begin
            if not Is_List (List) then
               return;
            end if;
            Cursor := List.First + 1;
            Next_Element (Cursor, Held, Found);
            if not Found then
               return;
            end if;
            Put (ASCII.LF & "<" & Tag & ">[");
            loop
               if not First_One then
                  Put (", ");
               end if;
               First_One := False;
               if Is_String (Held) then
                  Put ("`" & Decoded (Held) & "`");
               else
                  Put (Pythonic (Held));
               end if;
               Next_Element (Cursor, Held, Found);
               exit when not Found;
            end loop;
            Put ("]</" & Tag & ">");
         end Item_List;

         --  A value inside a tag named for its key: the JSON of a mapping,
         --  Python's str of anything else.
         procedure In_Tag (Key : String; Held : Span) is
         begin
            Put (ASCII.LF & "<" & Key & ">");
            if Is_Mapping (Held) then
               Put (Src (Held.First .. Held.Last));
            else
               Put (Pythonic (Held));
            end if;
            Put ("</" & Key & ">");
         end In_Tag;

         Whole : constant Span := Value_At (Src'First);
         Tool  : Span := Whole;
      begin
         if Present (Member (Whole, "function")) then
            Tool := Member (Whole, "function");
         end if;

         Put (ASCII.LF & "<function>" & ASCII.LF & "<name>");
         Put (Pythonic (Member (Tool, "name")));
         Put ("</name>");
         Put (ASCII.LF & "<description>");
         Put (Model_Runner.Text.Trim (Pythonic (Member (Tool, "description"))));
         Put ("</description>");
         Put (ASCII.LF & "<parameters>");

         declare
            Parameters : constant Span := Member (Tool, "parameters");
            Properties : constant Span := Member (Parameters, "properties");
            Cursor     : Natural;
            Key, Fields : Span;
            Found      : Boolean;
         begin
            if Is_Mapping (Properties) then
               Cursor := Properties.First + 1;
               loop
                  Next_Member (Cursor, Key, Fields, Found);
                  exit when not Found;
                  Put (ASCII.LF & "<parameter>");
                  Put (ASCII.LF & "<name>" & Decoded (Key) & "</name>");
                  if Present (Member (Fields, "type")) then
                     Put (ASCII.LF & "<type>"
                          & Pythonic (Member (Fields, "type")) & "</type>");
                  end if;
                  if Present (Member (Fields, "description")) then
                     Put (ASCII.LF & "<description>"
                          & Model_Runner.Text.Trim
                              (Pythonic (Member (Fields, "description")))
                          & "</description>");
                  end if;
                  Item_List (Member (Fields, "enum"), "enum");

                  declare
                     Inner : Natural := Fields.First + 1;
                     K, V  : Span;
                     More  : Boolean;
                  begin
                     if Is_Mapping (Fields) then
                        loop
                           Next_Member (Inner, K, V, More);
                           exit when not More;
                           declare
                              Name : constant String := Decoded (K);
                           begin
                              if Name /= "type" and then Name /= "description"
                                and then Name /= "enum"
                                and then Name /= "required"
                              then
                                 In_Tag (Name, V);
                              end if;
                           end;
                        end loop;
                     end if;
                  end;

                  Item_List (Member (Fields, "required"), "required");
                  Put (ASCII.LF & "</parameter>");
               end loop;
            end if;
            Item_List (Member (Parameters, "required"), "required");
         end;

         Put (ASCII.LF & "</parameters>");
         if Present (Member (Tool, "return")) then
            In_Tag ("return", Member (Tool, "return"));
         end if;
         Put (ASCII.LF & "</function>");

         return Ada.Strings.Unbounded.To_String (Out_Text);
      end Qwen_Tool_Of;

      --  Value of one term with its filter applied.
      --  What one filter makes of the text before it. The three that read
      --  the term rather than its text -- tojson and the two parameter
      --  writers -- are answered in Value_Of, where the term is at hand.
      function Filtered (Step : Filter_Step; Held : String) return String is
         package Chars renames Ada.Characters.Handling;
      begin
         case Step.Kind is
            when Filter_None | Filter_String | Filter_Safe | Filter_JSON
               | Filter_Params | Filter_Qwen_Params | Filter_Qwen_Tool
               | Filter_Min | Filter_Join | Filter_Map | Filter_Select
               | Filter_Reject | Filter_Select_Attr | Filter_Reject_Attr
               | Filter_Sort | Filter_Dict_Sort | Filter_Indent
               | Filter_Unique | Filter_List | Filter_First | Filter_Last
               | Filter_Float =>
               return Held;

            when Filter_Trim =>
               return Model_Runner.Text.Trim (Held);

            when Filter_Length =>
               return Model_Runner.Text.Image (Long_Long_Integer (Held'Length));

            when Filter_Lower =>
               return Chars.To_Lower (Held);

            when Filter_Upper =>
               return Chars.To_Upper (Held);

            when Filter_Capitalize =>
               --  The first letter up and the rest down, as the language
               --  does it.
               if Held'Length = 0 then
                  return Held;
               end if;
               return Chars.To_Upper (Held (Held'First))
                 & Chars.To_Lower (Held (Held'First + 1 .. Held'Last));

            when Filter_Title =>
               --  Every word's first letter up and the rest down, a word
               --  beginning after anything that is not a letter.
               declare
                  Result : String := Held;
                  Fresh  : Boolean := True;
               begin
                  for Index in Result'Range loop
                     if Chars.Is_Letter (Result (Index)) then
                        Result (Index) :=
                          (if Fresh then Chars.To_Upper (Result (Index))
                           else Chars.To_Lower (Result (Index)));
                        Fresh := False;
                     else
                        Fresh := True;
                     end if;
                  end loop;
                  return Result;
               end;

            when Filter_Int =>
               return Model_Runner.Text.Image (Number_Of (Held));

            when Filter_Default =>
               --  The stand-in where the value is empty, none or never set;
               --  the value where it is anything else.
               if Held'Length = 0 then
                  return Value_Of (Item.Operands.all (Step.Arg1));
               end if;
               return Held;

            when Filter_Replace =>
               declare
                  Old_Text : constant String :=
                    Value_Of (Item.Operands.all (Step.Arg1));
                  New_Text : constant String :=
                    Value_Of (Item.Operands.all (Step.Arg2));
                  Result   : Ada.Strings.Unbounded.Unbounded_String;
                  Index    : Natural := Held'First;
               begin
                  if Old_Text'Length = 0 then
                     return Held;
                  end if;
                  while Index <= Held'Last loop
                     if Index + Old_Text'Length - 1 <= Held'Last
                       and then Held (Index .. Index + Old_Text'Length - 1)
                                = Old_Text
                     then
                        Ada.Strings.Unbounded.Append (Result, New_Text);
                        Index := Index + Old_Text'Length;
                     else
                        Ada.Strings.Unbounded.Append (Result, Held (Index));
                        Index := Index + 1;
                     end if;
                  end loop;
                  return Ada.Strings.Unbounded.To_String (Result);
               end;
         end case;
      end Filtered;

      --  A term as a value: what it names, then each method in turn, then
      --  each filter, each taking what the one before it made.
      --  The elements of a list as spans, for the filters that walk one.
      Max_Elements : constant := 4096;
      type Span_Array is array (1 .. Max_Elements) of Span;

      procedure Elements_Of
        (Src : String; Spans : out Span_Array; Count : out Natural);
      function List_Of
        (Src : String; Spans : Span_Array; Count : Natural) return Held;

      function Method_On (Value : Held; Step : Method_Step) return Held is
      begin
         case Step.Kind is
            when Method_None =>
               return Value;

            when Method_Cut_From | Method_Cut_To =>
               --  A cut through a list keeps the elements from or before
               --  the position, counted as the language counts them; a
               --  cut through text is a cut through text.
               if Value.Kind in Value_Tools | Value_List | Value_Call
                 or else (Value.Kind = Value_Data
                          and then Is_JSON_List (Text_Of (Value)))
               then
                  declare
                     Src   : constant String := Listed (Value);
                     Spans : Span_Array;
                     Count : Natural;
                     Where : Long_Long_Integer :=
                       Number_Of (Value_Of (Item.Operands.all (Step.At_Operand)));
                     Kept  : Span_Array;
                     Held_Count : Natural := 0;
                  begin
                     Elements_Of (Src, Spans, Count);
                     if Where < 0 then
                        Where := Long_Long_Integer'Max
                          (0, Long_Long_Integer (Count) + Where);
                     end if;
                     for Index in 1 .. Count loop
                        if (Step.Kind = Method_Cut_From
                            and then Long_Long_Integer (Index) > Where)
                          or else (Step.Kind = Method_Cut_To
                                   and then Long_Long_Integer (Index) <= Where)
                        then
                           Held_Count := Held_Count + 1;
                           Kept (Held_Count) := Spans (Index);
                        end if;
                     end loop;
                     return List_Of (Src, Kept, Held_Count);
                  end;
               end if;
               return As_Text (Applied (Step, Printed (Value)));

            when Method_Strip | Method_Left_Strip | Method_Right_Strip
               | Method_Split_First | Method_Split_Last =>
               return As_Text (Applied (Step, Printed (Value)));

            when Method_Split_Whole =>
               --  The pieces as a list, which is what the language
               --  answers, and which a template then counts, indexes and
               --  walks.
               declare
                  Text   : constant String := Printed (Value);
                  Marker : constant String :=
                    Value_Of (Item.Operands.all (Step.At_Operand));
                  R      : Ada.Strings.Unbounded.Unbounded_String;
                  From   : Natural := Text'First;
                  Index  : Natural := Text'First;
               begin
                  Ada.Strings.Unbounded.Append (R, "[");
                  if Marker'Length = 0 then
                     Ada.Strings.Unbounded.Append (R, Quoted (Text));
                  else
                     while Index + Marker'Length - 1 <= Text'Last loop
                        if Text (Index .. Index + Marker'Length - 1) = Marker
                        then
                           Ada.Strings.Unbounded.Append
                             (R, Quoted (Text (From .. Index - 1)) & ", ");
                           Index := Index + Marker'Length;
                           From := Index;
                        else
                           Index := Index + 1;
                        end if;
                     end loop;
                     Ada.Strings.Unbounded.Append
                       (R, Quoted (Text (From .. Text'Last)));
                  end if;
                  Ada.Strings.Unbounded.Append (R, "]");
                  return As_Data (Ada.Strings.Unbounded.To_String (R));
               end;

            when Method_Starts_With | Method_Ends_With =>
               declare
                  Text : constant String := Printed (Value);
                  Wanted : constant String :=
                    (if Step.At_Operand = 0 then ""
                     else Value_Of (Item.Operands.all (Step.At_Operand)));
                  Yes : Boolean := False;
               begin
                  if Wanted'Length <= Text'Length then
                     if Step.Kind = Method_Starts_With then
                        Yes := Text (Text'First .. Text'First + Wanted'Length - 1)
                               = Wanted;
                     else
                        Yes := Text (Text'Last - Wanted'Length + 1 .. Text'Last)
                               = Wanted;
                     end if;
                  end if;
                  return (Kind => Value_Boolean, Start => (if Yes then 1 else 0),
                          others => <>);
               end;

            when Method_Index =>
               return Indexed
                 (Value, Value_Of (Item.Operands.all (Step.At_Operand)));

            when Method_Member =>
               return Along
                 (Value, Value_Of (Item.Operands.all (Step.At_Operand)));

            when Method_Replace =>
               declare
                  Text     : constant String := Printed (Value);
                  Old_Text : constant String :=
                    (if Step.At_Operand = 0 then ""
                     else Value_Of (Item.Operands.all (Step.At_Operand)));
                  New_Text : constant String :=
                    (if Step.Second_At = 0 then ""
                     else Value_Of (Item.Operands.all (Step.Second_At)));
                  R : Ada.Strings.Unbounded.Unbounded_String;
                  Index : Natural := Text'First;
               begin
                  if Old_Text'Length = 0 then
                     return As_Text (Text);
                  end if;
                  while Index <= Text'Last loop
                     if Index + Old_Text'Length - 1 <= Text'Last
                       and then Text (Index .. Index + Old_Text'Length - 1)
                                = Old_Text
                     then
                        Ada.Strings.Unbounded.Append (R, New_Text);
                        Index := Index + Old_Text'Length;
                     else
                        Ada.Strings.Unbounded.Append (R, Text (Index));
                        Index := Index + 1;
                     end if;
                  end loop;
                  return As_Text (Ada.Strings.Unbounded.To_String (R));
               end;

            when Method_Items =>
               --  The mapping itself; a loop walks it entry by entry.
               if Value.Kind = Value_JSON then
                  return As_Data (JSON_Text (Value));
               end if;
               return Value;

            when Method_Upper | Method_Lower | Method_Title
               | Method_Capitalize =>
               return As_Text
                 (Filtered
                    ((Kind => (case Step.Kind is
                                  when Method_Upper => Filter_Upper,
                                  when Method_Lower => Filter_Lower,
                                  when Method_Title => Filter_Title,
                                  when others => Filter_Capitalize),
                      others => <>),
                     Printed (Value)));

            when Method_Keys | Method_Values =>
               --  The mapping's keys, or its values, as a list.
               declare
                  Src    : constant String := JSON_Text (Value);
                  R      : Ada.Strings.Unbounded.Unbounded_String;
                  Cursor : Natural;
                  Key, Member : Span;
                  Found  : Boolean;
                  Any    : Boolean := False;
               begin
                  if not Is_JSON_Mapping (Src) then
                     return As_Data ("[]");
                  end if;
                  Ada.Strings.Unbounded.Append (R, "[");
                  Cursor := Src'First + 1;
                  loop
                     Next_Member (Src, Cursor, Key, Member, Found);
                     exit when not Found;
                     if Any then
                        Ada.Strings.Unbounded.Append (R, ", ");
                     end if;
                     Any := True;
                     Ada.Strings.Unbounded.Append
                       (R, (if Step.Kind = Method_Keys
                            then Src (Key.First .. Key.Last)
                            else Src (Member.First .. Member.Last)));
                  end loop;
                  Ada.Strings.Unbounded.Append (R, "]");
                  return As_Data (Ada.Strings.Unbounded.To_String (R));
               end;

            when Method_Get =>
               --  One member by name, or the stand-in where there is
               --  none and one was given.
               declare
                  Name : constant String :=
                    (if Step.At_Operand = 0 then ""
                     else Value_Of (Item.Operands.all (Step.At_Operand)));
                  R    : constant Held := Along (Value, Name);
               begin
                  if R.Kind = Value_Undefined and then Step.Second_At /= 0 then
                     return Held_Of (Item.Operands.all (Step.Second_At));
                  end if;
                  return R;
               end;
         end case;
      end Method_On;

      --  Any value that can be walked, as a JSON list: a list as it is,
      --  the tools as their definitions, a list of messages as objects
      --  with a role, a content and the calls the turn asked for, one
      --  turn's calls as objects with a name and arguments. What the list
      --  filters walk, so that "messages | selectattr('role', 'equalto',
      --  'user')" is a question with an answer.
      function Listed (Value : Held) return String is
         R : Ada.Strings.Unbounded.Unbounded_String;

         procedure Add (Text : String) is
         begin
            Ada.Strings.Unbounded.Append (R, Text);
         end Add;

         procedure Add_Call (At_Message, Which : Positive) is
         begin
            Add ("{""name"": "
                 & Quoted (Conv.Call_Name (Messages, At_Message, Which))
                 & ", ""arguments"": "
                 & Conv.Call_Arguments (Messages, At_Message, Which) & "}");
         end Add_Call;
      begin
         case Value.Kind is
            when Value_Data | Value_JSON | Value_Text =>
               return JSON_Text (Value);
            when Value_Tools =>
               Add ("[");
               for Index in 1 .. Tool_Count loop
                  if Index > 1 then
                     Add (", ");
                  end if;
                  Add (Offered_Tools.Definition (Tools.all, Index));
               end loop;
               Add ("]");
            when Value_List =>
               Add ("[");
               for At_Message in Value.Start .. Count loop
                  if At_Message > Value.Start then
                     Add (", ");
                  end if;
                  Add ("{""role"": "
                       & Quoted (Conv.Role_Name
                                   (Conv.Sender_At (Messages, At_Message)))
                       & ", ""content"": "
                       & Quoted (Conv.Content_At (Messages, At_Message)));
                  if Conv.Call_Count (Messages, At_Message) > 0 then
                     Add (", ""tool_calls"": [");
                     for Which in 1 .. Conv.Call_Count (Messages, At_Message)
                     loop
                        if Which > 1 then
                           Add (", ");
                        end if;
                        Add_Call (At_Message, Which);
                     end loop;
                     Add ("]");
                  end if;
                  Add ("}");
               end loop;
               Add ("]");
            when Value_Call =>
               if Value.Index /= 0 or else Value.Start = 0
                 or else Value.Start > Count
               then
                  return "[]";
               end if;
               Add ("[");
               for Which in 1 .. Conv.Call_Count (Messages, Value.Start) loop
                  if Which > 1 then
                     Add (", ");
                  end if;
                  Add_Call (Value.Start, Which);
               end loop;
               Add ("]");
            when others =>
               return "[]";
         end case;
         return Ada.Strings.Unbounded.To_String (R);
      end Listed;

      --  JSON text written out again with each container's members on
      --  lines of their own, Width blanks deeper a level, as Python's
      --  json.dumps(indent=Width) writes it.
      function Indented_JSON (Src : String; Width : Natural) return String is
         R     : Ada.Strings.Unbounded.Unbounded_String;
         Level : Natural := 0;
         Quote : Boolean := False;
         Index : Natural := Src'First;

         procedure Break_Line is
            Pad : constant String (1 .. Level * Width) := [others => ' '];
         begin
            Ada.Strings.Unbounded.Append (R, ASCII.LF & Pad);
         end Break_Line;

         --  Whether the container opening at Index is empty.
         function Empty_Ahead return Boolean is
            Look : constant Natural := Past_Blanks (Src, Index + 1);
         begin
            return Look <= Src'Last and then Src (Look) in ']' | '}';
         end Empty_Ahead;
      begin
         while Index <= Src'Last loop
            declare
               C : constant Character := Src (Index);
            begin
               if Quote then
                  Ada.Strings.Unbounded.Append (R, C);
                  if C = '\' and then Index < Src'Last then
                     Index := Index + 1;
                     Ada.Strings.Unbounded.Append (R, Src (Index));
                  elsif C = '"' then
                     Quote := False;
                  end if;
               elsif C = '"' then
                  Quote := True;
                  Ada.Strings.Unbounded.Append (R, C);
               elsif C in '[' | '{' then
                  Ada.Strings.Unbounded.Append (R, C);
                  if Empty_Ahead then
                     Index := Past_Blanks (Src, Index + 1);
                     Ada.Strings.Unbounded.Append (R, Src (Index));
                  else
                     Level := Level + 1;
                     Break_Line;
                  end if;
               elsif C in ']' | '}' then
                  Level := (if Level > 0 then Level - 1 else 0);
                  Break_Line;
                  Ada.Strings.Unbounded.Append (R, C);
               elsif C = ',' then
                  Ada.Strings.Unbounded.Append (R, C);
                  Break_Line;
               elsif C = ':' then
                  Ada.Strings.Unbounded.Append (R, ": ");
               elsif C in ' ' | ASCII.LF | ASCII.CR | ASCII.HT then
                  null;
               else
                  Ada.Strings.Unbounded.Append (R, C);
               end if;
            end;
            Index := Index + 1;
         end loop;
         return Ada.Strings.Unbounded.To_String (R);
      end Indented_JSON;

      --  Whether a value passes a test named in a select or reject, with
      --  the argument the test takes where it takes one.
      function Passes (V : Held; Test : String; Arg : Natural) return Boolean
      is
      begin
         if Test = "" then
            return Is_Truthy (V);
         elsif Test = "defined" then
            return V.Kind /= Value_Undefined;
         elsif Test = "undefined" then
            return V.Kind = Value_Undefined;
         elsif Test = "none" then
            return V.Kind = Value_None;
         elsif Test = "string" then
            return V.Kind = Value_Text;
         elsif Test = "number" then
            return V.Kind = Value_Number;
         elsif Test = "mapping" then
            return V.Kind = Value_JSON
              or else (V.Kind = Value_Data and then Is_JSON_Mapping (Text_Of (V)));
         elsif Test = "iterable" then
            return V.Kind in Value_Text | Value_Data | Value_JSON | Value_Tools
                             | Value_List;
         elsif Test = "true" then
            return V.Kind = Value_Boolean and then V.Start = 1;
         elsif Test = "false" then
            return V.Kind = Value_Boolean and then V.Start = 0;
         elsif Test in "equalto" | "eq" | "==" | "ne" | "!=" then
            declare
               Wanted : constant String :=
                 (if Arg = 0 then "" else Value_Of (Item.Operands.all (Arg)));
               Same   : constant Boolean := Printed (V) = Wanted;
            begin
               return (if Test in "ne" | "!=" then not Same else Same);
            end;
         elsif Test = "in" then
            declare
               Held_List : constant Held :=
                 (if Arg = 0 then Nothing
                  else Held_Of (Item.Operands.all (Arg)));
               Src : constant String := JSON_Text (Held_List);
               Cursor : Natural;
               Piece  : Span;
               More   : Boolean;
            begin
               if not Is_JSON_List (Src) then
                  return False;
               end if;
               Cursor := Src'First + 1;
               loop
                  Next_Element (Src, Cursor, Piece, More);
                  exit when not More;
                  if Printed (Read_Out (Src (Piece.First .. Piece.Last)))
                     = Printed (V)
                  then
                     return True;
                  end if;
               end loop;
               return False;
            end;
         end if;
         return False;
      end Passes;

      procedure Elements_Of
        (Src : String; Spans : out Span_Array; Count : out Natural) is
         Cursor : Natural;
         Piece  : Span;
         More   : Boolean;
      begin
         Count := 0;
         if not Is_JSON_List (Src) then
            return;
         end if;
         Cursor := Src'First + 1;
         loop
            Next_Element (Src, Cursor, Piece, More);
            exit when not More;
            if Count >= Max_Elements then
               --  A list longer than the filters walk refuses, naming the
               --  bound, rather than answering for the front of it.
               if not Refused then
                  Refused_Limit := Max_Elements;
               end if;
               Refuse (0, 0, E.Template_Variables_Too_Large);
               return;
            end if;
            Count := Count + 1;
            Spans (Count) := Piece;
         end loop;
      end Elements_Of;

      --  A list rebuilt from the spans kept, in order.
      function List_Of
        (Src : String; Spans : Span_Array; Count : Natural) return Held
      is
         R : Ada.Strings.Unbounded.Unbounded_String;
      begin
         Ada.Strings.Unbounded.Append (R, "[");
         for Index in 1 .. Count loop
            if Index > 1 then
               Ada.Strings.Unbounded.Append (R, ", ");
            end if;
            Ada.Strings.Unbounded.Append
              (R, Src (Spans (Index).First .. Spans (Index).Last));
         end loop;
         Ada.Strings.Unbounded.Append (R, "]");
         return As_Data (Ada.Strings.Unbounded.To_String (R));
      end List_Of;

      --  Whether one element sorts before another: numbers by value,
      --  anything else by its text, case folded unless asked otherwise.
      function Before (A, B : Held; Fold : Boolean) return Boolean is
      begin
         if A.Kind = Value_Number and then B.Kind = Value_Number then
            return Real_Of (Text_Of (A)) < Real_Of (Text_Of (B));
         end if;
         if Fold then
            return Ada.Characters.Handling.To_Lower (Printed (A))
                   < Ada.Characters.Handling.To_Lower (Printed (B));
         end if;
         return Printed (A) < Printed (B);
      end Before;

      function Filter_On (Value : Held; Step : Filter_Step) return Held is
      begin
         case Step.Kind is
            when Filter_None | Filter_Safe =>
               return Value;

            when Filter_String =>
               return As_Text (Printed (Value));

            when Filter_Length =>
               return As_Number (Long_Long_Integer (Length_Of (Value)));

            when Filter_JSON =>
               --  Indented where asked, as Python indents: one element a
               --  line, a nested container opening on the line of its
               --  key, and an empty one staying on one line.
               if Step.Arg1 /= 0 then
                  declare
                     Width : constant Natural :=
                       Natural'Max
                         (0, Natural (Number_Of
                               (Value_Of (Item.Operands.all (Step.Arg1)))));
                  begin
                     return As_Text (Indented_JSON (JSON_Text (Value), Width));
                  end;
               end if;
               return As_Text (JSON_Text (Value));

            when Filter_Params =>
               return As_Text (Params_Of (JSON_Text (Value)));

            when Filter_Qwen_Params =>
               return As_Text (Params_Of (JSON_Text (Value), Qwen => True));

            when Filter_Qwen_Tool =>
               return As_Text (Qwen_Tool_Of (JSON_Text (Value)));

            when Filter_Default =>
               if Value.Kind = Value_Undefined
                 or else (Value.Kind = Value_Text
                          and then Text_Of (Value) = "")
               then
                  return As_Text (Value_Of (Item.Operands.all (Step.Arg1)));
               end if;
               return Value;

            when Filter_Min =>
               --  The smallest number in a list.
               declare
                  Src    : constant String := JSON_Text (Value);
                  Cursor : Natural;
                  Piece  : Span;
                  Found  : Boolean;
                  Least  : Long_Float := 0.0;
                  Which  : Span := (1, 0);
                  Any    : Boolean := False;
               begin
                  if not Is_JSON_List (Src) then
                     return As_Text ("");
                  end if;
                  Cursor := Src'First + 1;
                  loop
                     Next_Element (Src, Cursor, Piece, Found);
                     exit when not Found;
                     declare
                        N : constant Long_Float :=
                          Real_Of (Decoded (Src (Piece.First .. Piece.Last)));
                     begin
                        if not Any or else N < Least then
                           Least := N;
                           Which := Piece;
                        end if;
                        Any := True;
                     end;
                  end loop;
                  return (if Any then Read_Out (Src (Which.First .. Which.Last))
                          else As_Text (""));
               end;

            when Filter_Int =>
               return As_Number (Number_Of (Printed (Value)));

            when Filter_Float =>
               return As_Number (Real_Image (Real_Of (Printed (Value))));

            when Filter_First =>
               return Element_At
                 ((if Value.Kind in Value_Tools | Value_List | Value_Call
                   then As_Data (Listed (Value)) else Value), 0);

            when Filter_Last =>
               return Element_At
                 ((if Value.Kind in Value_Tools | Value_List | Value_Call
                   then As_Data (Listed (Value)) else Value), -1);

            when Filter_List =>
               --  A list as it is; a mapping's keys; text as its characters.
               if Value.Kind = Value_Data and then Is_JSON_List (Text_Of (Value))
               then
                  return Value;
               elsif Value.Kind in Value_Tools | Value_List | Value_Call then
                  return As_Data (Listed (Value));
               elsif Value.Kind in Value_Data | Value_JSON
                 and then Is_JSON_Mapping (JSON_Text (Value))
               then
                  return Method_On
                    (Value, (Kind => Method_Keys, At_Operand => 0,
                             Second_At => 0));
               else
                  declare
                     T : constant String := Printed (Value);
                     R : Ada.Strings.Unbounded.Unbounded_String;
                  begin
                     Ada.Strings.Unbounded.Append (R, "[");
                     for Index in T'Range loop
                        if Index > T'First then
                           Ada.Strings.Unbounded.Append (R, ", ");
                        end if;
                        Ada.Strings.Unbounded.Append
                          (R, Quoted (T (Index .. Index)));
                     end loop;
                     Ada.Strings.Unbounded.Append (R, "]");
                     return As_Data (Ada.Strings.Unbounded.To_String (R));
                  end;
               end if;

            when Filter_Join =>
               --  The elements run together with the separator between
               --  them, each printed as it would be on its own, or one
               --  member of each where a member is named.
               declare
                  Src   : constant String := Listed (Value);
                  Sep   : constant String :=
                    (if Step.Arg1 = 0 then ""
                     else Value_Of (Item.Operands.all (Step.Arg1)));
                  Name  : constant String :=
                    (if Step.Arg2 = 0 then ""
                     else Value_Of (Item.Operands.all (Step.Arg2)));
                  Spans : Span_Array;
                  Count : Natural;
                  R     : Ada.Strings.Unbounded.Unbounded_String;
               begin
                  if Value.Kind = Value_Text then
                     return Value;
                  end if;
                  Elements_Of (Src, Spans, Count);
                  for Index in 1 .. Count loop
                     if Index > 1 then
                        Ada.Strings.Unbounded.Append (R, Sep);
                     end if;
                     declare
                        Each : constant Held :=
                          Read_Out (Src (Spans (Index).First
                                         .. Spans (Index).Last));
                     begin
                        Ada.Strings.Unbounded.Append
                          (R, Printed (if Name = "" then Each
                                       else Along (Each, Name)));
                     end;
                  end loop;
                  return As_Text (Ada.Strings.Unbounded.To_String (R));
               end;

            when Filter_Map =>
               --  One member of each element, as a list.
               declare
                  Src   : constant String := Listed (Value);
                  Name  : constant String :=
                    (if Step.Arg1 = 0 then ""
                     else Value_Of (Item.Operands.all (Step.Arg1)));
                  Spans : Span_Array;
                  Count : Natural;
                  R     : Ada.Strings.Unbounded.Unbounded_String;
               begin
                  Elements_Of (Src, Spans, Count);
                  Ada.Strings.Unbounded.Append (R, "[");
                  for Index in 1 .. Count loop
                     if Index > 1 then
                        Ada.Strings.Unbounded.Append (R, ", ");
                     end if;
                     declare
                        Member : constant Held :=
                          Along (Read_Out (Src (Spans (Index).First
                                                .. Spans (Index).Last)),
                                 Name);
                     begin
                        Ada.Strings.Unbounded.Append
                          (R, (if Member.Kind = Value_Undefined then "null"
                               else JSON_Text (Member)));
                     end;
                  end loop;
                  Ada.Strings.Unbounded.Append (R, "]");
                  return As_Data (Ada.Strings.Unbounded.To_String (R));
               end;

            when Filter_Select | Filter_Reject
               | Filter_Select_Attr | Filter_Reject_Attr =>
               --  The elements that pass the test, or fail it: the element
               --  itself, or the member named first.
               declare
                  By_Member : constant Boolean :=
                    Step.Kind in Filter_Select_Attr | Filter_Reject_Attr;
                  Keeping   : constant Boolean :=
                    Step.Kind in Filter_Select | Filter_Select_Attr;
                  Src   : constant String := Listed (Value);
                  Name  : constant String :=
                    (if By_Member and then Step.Arg1 /= 0
                     then Value_Of (Item.Operands.all (Step.Arg1)) else "");
                  Test_At : constant Natural :=
                    (if By_Member then Step.Arg2 else Step.Arg1);
                  Arg_At  : constant Natural :=
                    (if By_Member then Step.Arg3 else Step.Arg2);
                  Test  : constant String :=
                    (if Test_At = 0 then ""
                     else Value_Of (Item.Operands.all (Test_At)));
                  Spans : Span_Array;
                  Count : Natural;
                  Kept  : Span_Array;
                  Held_Count : Natural := 0;
               begin
                  Elements_Of (Src, Spans, Count);
                  for Index in 1 .. Count loop
                     declare
                        Each : constant Held :=
                          Read_Out (Src (Spans (Index).First
                                         .. Spans (Index).Last));
                        Asked : constant Held :=
                          (if By_Member then Along (Each, Name) else Each);
                     begin
                        if Passes (Asked, Test, Arg_At) = Keeping then
                           Held_Count := Held_Count + 1;
                           Kept (Held_Count) := Spans (Index);
                        end if;
                     end;
                  end loop;
                  return List_Of (Src, Kept, Held_Count);
               end;

            when Filter_Sort =>
               --  The list in order, by each element or by a member of
               --  it, reversed where asked. Insertion, the lists here
               --  being schemas and short.
               declare
                  Src     : constant String := Listed (Value);
                  Reverse_Order : constant Boolean :=
                    Step.Arg1 /= 0
                    and then Is_Truthy (Held_Of (Item.Operands.all (Step.Arg1)));
                  Fold    : constant Boolean :=
                    Step.Arg2 = 0
                    or else not Is_Truthy (Held_Of (Item.Operands.all (Step.Arg2)));
                  Name    : constant String :=
                    (if Step.Arg3 = 0 then ""
                     else Value_Of (Item.Operands.all (Step.Arg3)));
                  Spans   : Span_Array;
                  Count   : Natural;

                  function Key_Of (S : Span) return Held
                  is (if Name = ""
                      then Read_Out (Src (S.First .. S.Last))
                      else Along (Read_Out (Src (S.First .. S.Last)), Name));
               begin
                  Elements_Of (Src, Spans, Count);
                  for I in 2 .. Count loop
                     declare
                        Moving : constant Span := Spans (I);
                        J      : Natural := I;
                     begin
                        while J > 1
                          and then (if Reverse_Order
                                    then Before (Key_Of (Spans (J - 1)),
                                                 Key_Of (Moving), Fold)
                                    else Before (Key_Of (Moving),
                                                 Key_Of (Spans (J - 1)), Fold))
                        loop
                           Spans (J) := Spans (J - 1);
                           J := J - 1;
                        end loop;
                        Spans (J) := Moving;
                     end;
                  end loop;
                  return List_Of (Src, Spans, Count);
               end;

            when Filter_Dict_Sort =>
               --  A mapping as a list of [key, value] pairs, in key order
               --  -- or value order where asked -- reversed where asked.
               declare
                  Src   : constant String := Listed (Value);
                  Fold  : constant Boolean :=
                    Step.Arg1 = 0
                    or else not Is_Truthy (Held_Of (Item.Operands.all (Step.Arg1)));
                  By_Value : constant Boolean :=
                    Step.Arg2 /= 0
                    and then Value_Of (Item.Operands.all (Step.Arg2)) = "value";
                  Reverse_Order : constant Boolean :=
                    Step.Arg3 /= 0
                    and then Is_Truthy (Held_Of (Item.Operands.all (Step.Arg3)));
                  Keys, Members : Span_Array;
                  Count  : Natural := 0;
                  Cursor : Natural;
                  Key, Member : Span;
                  Found  : Boolean;
                  R      : Ada.Strings.Unbounded.Unbounded_String;

                  function Key_Of (I : Natural) return Held
                  is (if By_Value
                      then Read_Out (Src (Members (I).First .. Members (I).Last))
                      else As_Text (Decoded (Src (Keys (I).First
                                                  .. Keys (I).Last))));
               begin
                  if not Is_JSON_Mapping (Src) then
                     return As_Data ("[]");
                  end if;
                  Cursor := Src'First + 1;
                  loop
                     Next_Member (Src, Cursor, Key, Member, Found);
                     exit when not Found or else Count >= Max_Elements;
                     Count := Count + 1;
                     Keys (Count) := Key;
                     Members (Count) := Member;
                  end loop;
                  for I in 2 .. Count loop
                     declare
                        K : constant Span := Keys (I);
                        M : constant Span := Members (I);
                        J : Natural := I;
                     begin
                        while J > 1
                          and then (if Reverse_Order
                                    then Before (Key_Of (J - 1), Key_Of (I), Fold)
                                    else Before (Key_Of (I), Key_Of (J - 1), Fold))
                        loop
                           Keys (J) := Keys (J - 1);
                           Members (J) := Members (J - 1);
                           J := J - 1;
                        end loop;
                        Keys (J) := K;
                        Members (J) := M;
                        --  Key_Of (I) read the moving pair, which is now
                        --  at J: the comparison above is against the
                        --  pair it was, read before the shift.
                     end;
                  end loop;
                  Ada.Strings.Unbounded.Append (R, "[");
                  for I in 1 .. Count loop
                     if I > 1 then
                        Ada.Strings.Unbounded.Append (R, ", ");
                     end if;
                     Ada.Strings.Unbounded.Append
                       (R, "[" & Src (Keys (I).First .. Keys (I).Last) & ", "
                        & Src (Members (I).First .. Members (I).Last) & "]");
                  end loop;
                  Ada.Strings.Unbounded.Append (R, "]");
                  return As_Data (Ada.Strings.Unbounded.To_String (R));
               end;

            when Filter_Indent =>
               --  Every line after the first indented by the width, the
               --  first too where asked, blank lines left alone unless
               --  asked.
               declare
                  T     : constant String := Printed (Value);
                  Width : constant Natural :=
                    (if Step.Arg1 = 0 then 4
                     else Natural'Max
                            (0, Natural (Number_Of
                                  (Value_Of (Item.Operands.all (Step.Arg1))))));
                  First : constant Boolean :=
                    Step.Arg2 /= 0
                    and then Is_Truthy (Held_Of (Item.Operands.all (Step.Arg2)));
                  Blank : constant Boolean :=
                    Step.Arg3 /= 0
                    and then Is_Truthy (Held_Of (Item.Operands.all (Step.Arg3)));
                  Pad   : constant String (1 .. Width) := [others => ' '];
                  R     : Ada.Strings.Unbounded.Unbounded_String;
                  At_Line_Start : Boolean := True;
                  Line_Number   : Natural := 1;

                  function Line_Is_Blank (From : Natural) return Boolean is
                     I : Natural := From;
                  begin
                     while I <= T'Last and then T (I) /= ASCII.LF loop
                        if T (I) /= ' ' and then T (I) /= ASCII.HT then
                           return False;
                        end if;
                        I := I + 1;
                     end loop;
                     return True;
                  end Line_Is_Blank;
               begin
                  for I in T'Range loop
                     if At_Line_Start then
                        if (Line_Number > 1 or else First)
                          and then (Blank or else not Line_Is_Blank (I))
                        then
                           Ada.Strings.Unbounded.Append (R, Pad);
                        end if;
                        At_Line_Start := False;
                     end if;
                     Ada.Strings.Unbounded.Append (R, T (I));
                     if T (I) = ASCII.LF then
                        At_Line_Start := True;
                        Line_Number := Line_Number + 1;
                     end if;
                  end loop;
                  return As_Text (Ada.Strings.Unbounded.To_String (R));
               end;

            when Filter_Unique =>
               --  The elements with every repeat after the first dropped.
               declare
                  Src   : constant String := Listed (Value);
                  Spans : Span_Array;
                  Count : Natural;
                  Kept  : Span_Array;
                  Held_Count : Natural := 0;
               begin
                  Elements_Of (Src, Spans, Count);
                  for I in 1 .. Count loop
                     declare
                        Seen : Boolean := False;
                     begin
                        for J in 1 .. Held_Count loop
                           if Src (Spans (I).First .. Spans (I).Last)
                              = Src (Kept (J).First .. Kept (J).Last)
                           then
                              Seen := True;
                              exit;
                           end if;
                        end loop;
                        if not Seen then
                           Held_Count := Held_Count + 1;
                           Kept (Held_Count) := Spans (I);
                        end if;
                     end;
                  end loop;
                  return List_Of (Src, Kept, Held_Count);
               end;

            when Filter_Trim | Filter_Lower | Filter_Upper
               | Filter_Capitalize | Filter_Title | Filter_Replace =>
               return As_Text (Filtered (Step, Printed (Value)));
         end case;
      end Filter_On;

      --  What is inside a bracket after a value: a position where it is
      --  a number, and a member's name where it is not -- t['function']
      --  and t.function are the same member.
      function Indexed (Value : Held; Key : String) return Held is
         Numeric : constant Boolean :=
           Key'Length > 0
           and then (for all C of Key => C in '0' .. '9' | '-')
           and then Key (Key'Last) in '0' .. '9';
      begin
         if Numeric then
            return Element_At (Value, Number_Of (Key));
         end if;
         return Along (Value, Key);
      end Indexed;

      --  One message as the JSON its list would hold it as.
      function Element_Of_Listed (One : Held) return String is
         Whole : constant String :=
           Listed ((Kind => Value_List, Start => One.Start, others => <>));
         Cursor : Natural := Whole'First + 1;
         Piece  : Span;
         Found  : Boolean;
      begin
         if One.Start = 0 or else One.Start > Count then
            return "null";
         end if;
         Next_Element (Whole, Cursor, Piece, Found);
         return (if Found then Whole (Piece.First .. Piece.Last) else "null");
      end Element_Of_Listed;

      --  One operand as JSON, for a list or mapping written out: a number
      --  where it is one, a mapping or list as its JSON, none as null,
      --  a truth as one, and text as a JSON string.
      function Encoded (Element : Operand) return String is
      begin
         if Element.Count = 1 then
            declare
               One : constant Held := Resolve (Element.Terms (1));
            begin
               if One.Kind in Value_Data | Value_Number | Value_None
                              | Value_Boolean | Value_JSON
               then
                  return JSON_Text (One);
               elsif Element.Terms (1).Numeric then
                  return Model_Runner.Text.Image (Number_Of (Printed (One)));
               elsif One.Kind in Value_Tools | Value_List | Value_Call then
                  return Listed (One);
               elsif One.Kind = Value_Message then
                  return Element_Of_Listed (One);
               else
                  return Quoted (Printed (One));
               end if;
            end;
         elsif Is_Sum (Element) then
            return Value_Of (Element);
         end if;
         return Quoted (Value_Of (Element));
      end Encoded;

      function Base_Of (Value : Term) return Held is
      begin
         case Value.Kind is
            when Term_Variable =>
               declare
                  R : Held := Held_Of (Value.Offset);
               begin
                  if Value.Path_Len > 0 then
                     R := Along
                       (R, Item.Source.all
                             (Value.Path_At + 1
                              .. Value.Path_At + Value.Path_Len));
                  end if;
                  if Value.Indexes then
                     R := Indexed
                       (R, Value_Of (Item.Operands.all (Value.Index_At)));
                  end if;
                  if Value.Tail_Len > 0 then
                     R := Along
                       (R, Item.Source.all
                             (Value.Tail_At + 1
                              .. Value.Tail_At + Value.Tail_Len));
                  end if;
                  return R;
               end;

            when Term_List =>
               --  A list written out, made of what its elements are worth:
               --  a number where the element is one by construction or
               --  holds one, a mapping or list as its JSON, text as a JSON
               --  string.
               declare
                  R : Ada.Strings.Unbounded.Unbounded_String;
               begin
                  Ada.Strings.Unbounded.Append (R, "[");
                  for Which in 1 .. Value.Length loop
                     if Which > 1 then
                        Ada.Strings.Unbounded.Append (R, ", ");
                     end if;
                     Ada.Strings.Unbounded.Append
                       (R, Encoded (Item.Operands.all (Value.Index_At + Which - 1)));
                  end loop;
                  Ada.Strings.Unbounded.Append (R, "]");
                  return As_Data (Ada.Strings.Unbounded.To_String (R));
               end;

            when Term_Dict =>
               --  A mapping written out: each key as its text, each value
               --  as a list's element is.
               declare
                  R : Ada.Strings.Unbounded.Unbounded_String;
               begin
                  Ada.Strings.Unbounded.Append (R, "{");
                  for Which in 1 .. Value.Length loop
                     if Which > 1 then
                        Ada.Strings.Unbounded.Append (R, ", ");
                     end if;
                     Ada.Strings.Unbounded.Append
                       (R, Quoted (Value_Of
                                     (Item.Operands.all
                                        (Value.Index_At + 2 * Which - 2)))
                           & ": "
                           & Encoded (Item.Operands.all
                                        (Value.Index_At + 2 * Which - 1)));
                  end loop;
                  Ada.Strings.Unbounded.Append (R, "}");
                  return As_Data (Ada.Strings.Unbounded.To_String (R));
               end;

            when Term_Loop_Previous | Term_Loop_Next =>
               --  The message beside the bound one in a list loop, or
               --  nothing at either end and outside such a loop.
               declare
                  R : Held := Nothing;
                  Beside : Natural := 0;
               begin
                  if Loop_Depth > 0
                    and then Loops (Loop_Depth).Kind = Over_Messages
                  then
                     declare
                        L : Loop_State renames Loops (Loop_Depth);
                        Here : constant Natural := Slots (L.Var).Start;
                     begin
                        if Value.Kind = Term_Loop_Previous then
                           if (not L.Reversed and then Here > L.From)
                             or else (L.Reversed and then Here < L.To)
                           then
                              Beside := (if L.Reversed then Here + 1
                                         else Here - 1);
                           end if;
                        else
                           if (not L.Reversed and then Here < L.To)
                             or else (L.Reversed and then Here > L.From)
                           then
                              Beside := (if L.Reversed then Here - 1
                                         else Here + 1);
                           end if;
                        end if;
                     end;
                  elsif Loop_Depth > 0
                    and then Loops (Loop_Depth).Kind = Legacy_List
                  then
                     if Value.Kind = Term_Loop_Previous then
                        if Current > Loop_Start then
                           Beside := Current - 1;
                        end if;
                     elsif Current < Count and then Current > 0 then
                        Beside := Current + 1;
                     end if;
                  end if;
                  if Beside /= 0 then
                     R := (Kind => Value_Message, Start => Beside,
                           others => <>);
                     if Value.Path_Len > 0 then
                        R := Along
                          (R, Item.Source.all
                                (Value.Path_At + 1
                                 .. Value.Path_At + Value.Path_Len));
                     end if;
                  end if;
                  return R;
               end;

            when Term_Call_Arguments =>
               return As_Data (Raw_Of (Value));

            when Term_Message_Calls =>
               return Field_Of
                 ((Kind => Value_Message, Start => Bound_Message,
                   others => <>), "tool_calls");

            when Term_Group =>
               declare
                  Inner : Operand renames Item.Operands.all (Value.Offset);
               begin
                  if Inner.Count = 1 and then not Is_Sum (Inner) then
                     return Resolve (Inner.Terms (1));
                  end if;
                  return Held_Of (Inner);
               end;

            when Term_Literal =>
               if Value.Numeric then
                  return As_Number (Raw_Of (Value));
               end if;
               return As_Text (Raw_Of (Value));

            when Term_Loop_Index_Zero | Term_Loop_Index_One
               | Term_Loop_Length | Term_Loop_Rev_Index_Zero
               | Term_Loop_Rev_Index_One =>
               return As_Number (Raw_Of (Value));

            when Term_True =>
               return (Kind => Value_Boolean, Start => 1, others => <>);
            when Term_False =>
               return (Kind => Value_Boolean, Start => 0, others => <>);
            when Term_None =>
               return (Kind => Value_None, others => <>);

            when Term_Condition =>
               return (Kind => Value_Boolean,
                       Start => (if Truth_Of (Item.Conditions.all (Value.Offset))
                                 then 1 else 0),
                       others => <>);

            when Term_Or | Term_And =>
               declare
                  Left : constant Held :=
                    Held_Of (Item.Operands.all (Value.Index_At));
               begin
                  if Is_Truthy (Left) = (Value.Kind = Term_Or) then
                     return Left;
                  end if;
                  return Held_Of (Item.Operands.all (Value.Length));
               end;

            when Term_Choice =>
               if Truth_Of (Item.Conditions.all (Value.Offset)) then
                  return Held_Of (Item.Operands.all (Value.Index_At));
               elsif Value.Length = 0 then
                  return Nothing;
               else
                  return Held_Of (Item.Operands.all (Value.Length));
               end if;

            when Term_Unsupported =>
               if Value.Why = E.Template_Unknown_Variable then
                  if not Testing then
                     Refuse (Value.Offset, Value.Length, Value.Why);
                  end if;
                  return Nothing;
               end if;
               return As_Text (Raw_Of (Value));

            when others =>
               return As_Text (Raw_Of (Value));
         end case;
      end Base_Of;

      function Resolve (Value : Term) return Held is
         R : Held := Base_Of (Value);
      begin
         for M in 1 .. Value.Chained loop
            R := Method_On (R, Value.Methods (M));
         end loop;
         for F in 1 .. Value.Filtered loop
            R := Filter_On (R, Value.Filters (F));
         end loop;
         return R;
      end Resolve;

      function Value_Of (Value : Term) return String is
         R : constant Held := Resolve (Value);
      begin
         case R.Kind is
            when Value_Undefined =>
               --  A name never assigned is nothing in a condition and a
               --  refusal in the output, for the reason Raw_Of gives.
               if not Testing and then Value.Kind = Term_Variable
                 and then Value.Path_Len = 0 and then not Value.Indexes
               then
                  Refuse (Item.Names (Value.Offset).Offset,
                          Item.Names (Value.Offset).Length,
                          E.Template_Unknown_Variable);
               end if;
               return "";
            when Value_Boolean | Value_None =>
               --  Truth in a condition, and Python's spelling in the
               --  output.
               if Testing then
                  return (if Is_Truthy (R) then "true" else "");
               end if;
               return Printed (R);
            when Value_Tools | Value_List | Value_Message | Value_Call
               | Value_JSON =>
               --  Positions, not text. A condition asks whether there is
               --  something there; the output may not print one.
               if Testing then
                  return (if Is_Truthy (R) then "true" else "");
               end if;
               if Value.Kind = Term_Variable then
                  Refuse (Item.Names (Value.Offset).Offset,
                          Item.Names (Value.Offset).Length,
                          E.Template_Unsupported_Construct);
               else
                  Refuse (Value.Offset, Value.Length,
                          E.Template_Unsupported_Construct);
               end if;
               return "";
            when others =>
               return Printed (R);
         end case;
      end Value_Of;

      --  Write an operand straight to the output. Emitting term by term
      --  avoids a temporary the size of the whole target, which message
      --  content can legitimately approach.
      --  Whether an operand written into it prints as one number or as one
      --  run of text.
      --
      --  Both readers of an operand ask this and they have to agree: a
      --  template that works a position out in a set and prints the same
      --  expression elsewhere means the same thing in both places.
      --
      --  A subtraction is a sum outright: nothing else is written with a
      --  minus. A plus is one when every term of it is a number by
      --  construction -- a bare number, a loop counter, a length -- which
      --  is the language's own rule read off what the terms are rather than
      --  off what they happen to hold. Two pieces of text joined with a
      --  plus are still run together, and two numbers added: a template
      --  asking for messages[loop.index0 + 1] means the message after this
      --  one and not the one at position "01".
      function Is_Sum (Value : Operand) return Boolean is
      begin
         if Value.Count <= 1 then
            return False;
         end if;

         --  A '~' anywhere makes the whole of it text: the language turns
         --  both sides of one into text, and a number beside text is text.
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

         if (for all Index in 1 .. Value.Count =>
               Value.Terms (Index).Numeric)
         then
            return True;
         end if;

         --  Or every term is worth a number when it is read, which the
         --  language decides then and not when the template is compiled:
         --  a name holds what it was assigned. Asked only of terms that
         --  cost nothing to read twice -- names, numbers, loop counters,
         --  bracketed groups -- and answered no for anything else, which
         --  runs together as it always did.
         for Index in 1 .. Value.Count loop
            declare
               T : Term renames Value.Terms (Index);
            begin
               if T.Kind not in Term_Literal | Term_Variable | Term_Group
                                | Term_Loop_Index_Zero | Term_Loop_Index_One
                 or else T.Chained > 0 or else T.Filtered > 0
                 or else Resolve (T).Kind /= Value_Number
               then
                  return False;
               end if;
            end;
         end loop;
         return True;
      end Is_Sum;

      procedure Emit_Operand (Value : Operand) is
      begin
         --  A sum is printed as the number it comes to, and anything else
         --  one term at a time: a run of text is written out as it is
         --  reached rather than gathered up first, because what a template
         --  prints has no bound worth holding in one place.
         if Is_Sum (Value) then
            Put (Value_Of (Value));
            return;
         end if;

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

      --  A number's text as binary64, zero where it is not one.
      function Real_Of (Text : String) return Long_Float is
         Trimmed : constant String := Model_Runner.Text.Trim (Text);
      begin
         if Trimmed'Length = 0 then
            return 0.0;
         end if;
         return Long_Float'Value (Trimmed);
      exception
         when others =>
            return Long_Float (Number_Of (Trimmed));
      end Real_Of;

      --  A binary64 written as Python writes one: the fewest digits that
      --  read back as the same number, a point and at least one digit
      --  after it, and an exponent from 1e16 up and below 1e-4. The
      --  digits come from the C library, which rounds them correctly;
      --  Ada's own image does not go to seventeen.
      function Real_Image (X : Long_Float) return String is
         function Snprintf
           (Buffer : Interfaces.C.Strings.chars_ptr;
            Size   : Interfaces.C.size_t;
            Format : Interfaces.C.Strings.chars_ptr;
            Places : Interfaces.C.int;
            Value  : Interfaces.C.double) return Interfaces.C.int
           with Import, Convention => C_Variadic_3,
                External_Name => "snprintf";

         Room   : Interfaces.C.Strings.chars_ptr :=
           Interfaces.C.Strings.New_String ([1 .. 64 => ' ']);
         Format : Interfaces.C.Strings.chars_ptr :=
           Interfaces.C.Strings.New_String ("%.*e");
         Chosen : Ada.Strings.Unbounded.Unbounded_String;
      begin
         if X /= X then
            Interfaces.C.Strings.Free (Room);
            Interfaces.C.Strings.Free (Format);
            return "nan";
         elsif X > Long_Float'Last or else X < Long_Float'First then
            Interfaces.C.Strings.Free (Room);
            Interfaces.C.Strings.Free (Format);
            return (if X > 0.0 then "inf" else "-inf");
         end if;

         for Places in 0 .. 16 loop
            declare
               Written : constant Interfaces.C.int :=
                 Snprintf (Room, 64, Format, Interfaces.C.int (Places),
                           Interfaces.C.double (X));
               pragma Unreferenced (Written);
               Said : constant String := Interfaces.C.Strings.Value (Room);
            begin
               Chosen := Ada.Strings.Unbounded.To_Unbounded_String (Said);
               exit when Long_Float'Value (Said) = X;
            end;
         end loop;
         Interfaces.C.Strings.Free (Room);
         Interfaces.C.Strings.Free (Format);

         --  d.ddde[+-]XX, taken apart and put together Python's way.
         declare
            Said     : constant String :=
              Ada.Strings.Unbounded.To_String (Chosen);
            At_E     : constant Natural := Ada.Strings.Fixed.Index (Said, "e");
            Negative : constant Boolean := Said (Said'First) = '-';
            Mantissa : constant String :=
              Said ((if Negative then Said'First + 1 else Said'First)
                    .. At_E - 1);
            Exponent : constant Integer :=
              Integer'Value (Said (At_E + 1 .. Said'Last));
            Digits_Only : constant String :=
              Mantissa (Mantissa'First)
              & (if Mantissa'Length > 2
                 then Mantissa (Mantissa'First + 2 .. Mantissa'Last) else "");
            Sign : constant String := (if Negative then "-" else "");
         begin
            if Exponent >= 16 or else Exponent < -4 then
               declare
                  Exp_Image : constant String :=
                    Model_Runner.Text.Image (Long_Long_Integer (abs Exponent));
               begin
                  return Sign & Mantissa & "e"
                    & (if Exponent < 0 then "-" else "+")
                    & (if Exp_Image'Length < 2 then "0" else "") & Exp_Image;
               end;
            elsif Exponent >= 0 then
               declare
                  Whole : constant Natural := Exponent + 1;
               begin
                  if Digits_Only'Length <= Whole then
                     return Sign & Digits_Only
                       & String'[1 .. Whole - Digits_Only'Length => '0']
                       & ".0";
                  end if;
                  return Sign
                    & Digits_Only (Digits_Only'First
                                   .. Digits_Only'First + Whole - 1)
                    & "."
                    & Digits_Only (Digits_Only'First + Whole
                                   .. Digits_Only'Last);
               end;
            else
               return Sign & "0." & String'[1 .. -Exponent - 1 => '0']
                 & Digits_Only;
            end if;
         end;
      end Real_Image;

      --  Whether a sum is worked out in binary64: any term that is not a
      --  whole number, or a true division anywhere in it.
      function Uses_Reals (Value : Operand) return Boolean is
      begin
         for Index in 1 .. Value.Count loop
            if Index > 1 and then Value.Terms (Index).Join = Join_Divide then
               return True;
            end if;
            if Is_Real (Value_Of (Value.Terms (Index))) then
               return True;
            end if;
         end loop;
         return False;
      end Uses_Reals;

      function Value_Of (Value : Operand) return String is
         --  Only the filled prefix is ever returned, but defining the whole
         --  buffer costs a kilobyte on a path that is not hot and removes the
         --  question of whether that is really true.
         Result : String (1 .. Max_Comparison) := [others => ' '];
         Filled : Natural := 0;

         Arithmetic : constant Boolean := Is_Sum (Value);
      begin
         --  A sum is evaluated rather than run together, and its answer is
         --  the number's own text: everything downstream of an operand takes
         --  text, and a number written down is still a number.
         --  Products before sums, as the language binds them: a run of
         --  terms joined by the multiplicative joins is worked out as it is
         --  read, and added to or taken from the total where a plus or a
         --  minus ends it. Zero divides nothing, and a division that does
         --  not come out whole is not a whole number, which is the only
         --  kind this engine writes: both refuse where they are read.
         --  In binary64 where any term is not a whole number or a true
         --  division stands anywhere, as the language works it: 7 / 2 is
         --  3.5 and 8 / 2 is 4.0, and 1.5 + 1 is 2.5.
         if Arithmetic and then Uses_Reals (Value) then
            declare
               Total   : Long_Float := 0.0;
               Current : Long_Float :=
                 (if Value.Count = 0 then 0.0
                  else Real_Of (Value_Of (Value.Terms (1))));
               Sign    : Join_Kind := Join_Plus;

               procedure Settle is
               begin
                  if Sign = Join_Minus then
                     Total := Total - Current;
                  else
                     Total := Total + Current;
                  end if;
               end Settle;
            begin
               for Index in 2 .. Value.Count loop
                  declare
                     Next : constant Long_Float :=
                       Real_Of (Value_Of (Value.Terms (Index)));
                     Join : constant Join_Kind := Value.Terms (Index).Join;
                  begin
                     case Join is
                        when Join_Plus | Join_Minus | Join_Concat =>
                           Settle;
                           Sign := Join;
                           Current := Next;
                        when Join_Times =>
                           Current := Current * Next;
                        when Join_Divide | Join_Floor | Join_Modulo =>
                           if Next = 0.0 then
                              Refuse (Value.Terms (Index).Join_At,
                                      Value.Terms (Index).Join_Len,
                                      E.Template_Unsupported_Construct);
                              return "0";
                           end if;
                           if Join = Join_Divide then
                              Current := Current / Next;
                           elsif Join = Join_Floor then
                              Current := Long_Float'Floor (Current / Next);
                           else
                              Current :=
                                Current - Next * Long_Float'Floor (Current / Next);
                           end if;
                     end case;
                  end;
               end loop;
               Settle;
               return Real_Image (Total);
            end;
         end if;

         if Arithmetic then
            declare
               Total   : Long_Long_Integer := 0;
               Current : Long_Long_Integer :=
                 (if Value.Count = 0 then 0
                  else Number_Of (Value_Of (Value.Terms (1))));
               Sign    : Join_Kind := Join_Plus;

               procedure Settle is
               begin
                  if Sign = Join_Minus then
                     Total := Total - Current;
                  else
                     Total := Total + Current;
                  end if;
               end Settle;
            begin
               for Index in 2 .. Value.Count loop
                  declare
                     Next : constant Long_Long_Integer :=
                       Number_Of (Value_Of (Value.Terms (Index)));
                     Join : constant Join_Kind := Value.Terms (Index).Join;
                  begin
                     case Join is
                        when Join_Plus | Join_Minus | Join_Concat =>
                           Settle;
                           Sign := Join;
                           Current := Next;
                        when Join_Times =>
                           Current := Current * Next;
                        when Join_Divide | Join_Floor | Join_Modulo =>
                           if Next = 0 then
                              Refuse (Value.Terms (Index).Join_At,
                                      Value.Terms (Index).Join_Len,
                                      E.Template_Unsupported_Construct);
                              return "0";
                           end if;
                           if Join = Join_Modulo then
                              Current := Current mod Next;
                           elsif Join = Join_Floor then
                              --  The language's // rounds towards minus
                              --  infinity, which is what mod pairs with.
                              Current := (Current - (Current mod Next)) / Next;
                           else
                              Refuse (Value.Terms (Index).Join_At,
                                      Value.Terms (Index).Join_Len,
                                      E.Template_Unsupported_Construct);
                              return "0";
                           end if;
                     end case;
                  end;
               end loop;
               Settle;
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

      --  Whether a name has been given a value on the path taken so far.
      --  Asking is not reading: a name the template never assigns is a name
      --  this answers False about, and reading it stays an error.
      function Is_Defined (Value : Operand) return Boolean is
      begin
         if Value.Count /= 1 then
            return False;
         end if;
         case Value.Terms (1).Kind is
            when Term_Variable | Term_Loop_Previous | Term_Loop_Next
               | Term_Message_Calls =>
               return Resolve (Value.Terms (1)).Kind /= Value_Undefined;
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
                      and then Resolve (Value.Terms (1)).Kind = Value_None)
                     or else Value.Terms (1).Kind = Term_None);
      end Is_None;

      --  The value of a one-term operand, or text of a longer one.
      function Held_Of (Value : Operand) return Held is
      begin
         if Value.Count = 1 and then not Is_Sum (Value) then
            return Resolve (Value.Terms (1));
         end if;
         if Is_Sum (Value) then
            return As_Number (Value_Of (Value));
         end if;
         return As_Text (Value_Of (Value));
      end Held_Of;

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
               Result := Is_Truthy (Held_Of (Value.Left));

            when Compare_Equal | Compare_Not_Equal =>
               --  The same text, and the same kind of thing where both
               --  sides are one: a number and the text of that number are
               --  not equal, as the language has it.
               declare
                  Left  : constant String := Value_Of (Value.Left);
                  Right : constant String := Value_Of (Value.Right);
                  Same  : Boolean := Left = Right;
               begin
                  if Same then
                     declare
                        L : constant Held := Held_Of (Value.Left);
                        R : constant Held := Held_Of (Value.Right);
                     begin
                        if (L.Kind = Value_Number) /= (R.Kind = Value_Number)
                          and then L.Kind in Value_Text | Value_Number
                          and then R.Kind in Value_Text | Value_Number
                        then
                           Same := False;
                        end if;
                     end;
                  end if;
                  Result :=
                    (if Value.Operator = Compare_Equal then Same else not Same);
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
                  Right  : constant Held := Held_Of (Value.Right);
                  Held   : constant String :=
                    (if Right.Kind = Value_Data then Text_Of (Right)
                     else Printed (Right));
                  Found  : Boolean := False;
               begin
                  if Right.Kind = Value_Message then
                     --  A message named by position: the fields it has,
                     --  as "'x' in message" answers them.
                     Found := Needle = "role" or else Needle = "content"
                       or else (Needle = "tool_calls"
                                and then Right.Start in 1 .. Count
                                and then Conv.Call_Count (Messages, Right.Start)
                                         > 0);
                  elsif Right.Kind = Value_Data and then Is_JSON_Mapping (Held)
                  then
                     --  Whether the mapping has a member of that name.
                     Found := Member_Of (Held, Needle).Kind /= Value_Undefined;
                  elsif Right.Kind = Value_JSON then
                     Found := Member_Of (JSON_Text (Right), Needle).Kind
                              /= Value_Undefined;
                  elsif Right.Kind = Value_Data and then Is_JSON_List (Held) then
                     --  Whether the left side is one of the list's
                     --  elements, which is the other question this word
                     --  asks.
                     declare
                        Cursor : Natural := Held'First + 1;
                        Piece  : Span;
                        More   : Boolean;
                     begin
                        loop
                           Next_Element (Held, Cursor, Piece, More);
                           exit when not More;
                           if Decoded (Held (Piece.First .. Piece.Last))
                              = Needle
                           then
                              Found := True;
                              exit;
                           end if;
                        end loop;
                     end;
                  elsif Needle'Length > 0
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
                  Left_Text  : constant String := Value_Of (Value.Left);
                  Right_Text : constant String := Value_Of (Value.Right);
               begin
                  if Is_Real (Left_Text) or else Is_Real (Right_Text) then
                     declare
                        Left  : constant Long_Float := Real_Of (Left_Text);
                        Right : constant Long_Float := Real_Of (Right_Text);
                     begin
                        Result :=
                          (case Value.Operator is
                              when Compare_Less          => Left < Right,
                              when Compare_Less_Or_Equal => Left <= Right,
                              when Compare_Greater       => Left > Right,
                              when others                => Left >= Right);
                     end;
                  else
                     declare
                        Left  : constant Long_Long_Integer :=
                          Number_Of (Left_Text);
                        Right : constant Long_Long_Integer :=
                          Number_Of (Right_Text);
                     begin
                        Result :=
                          (case Value.Operator is
                              when Compare_Less          => Left < Right,
                              when Compare_Less_Or_Equal => Left <= Right,
                              when Compare_Greater       => Left > Right,
                              when others                => Left >= Right);
                     end;
                  end if;
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
               --  Text is a string, and so is a JSON string read out of a
               --  mapping; a mapping, a list, a number, a message, none and
               --  a name never assigned are not.
               declare
                  V    : constant Held := Held_Of (Value.Left);
                  Says : constant Boolean :=
                    V.Kind = Value_Text
                    or else (V.Kind = Value_Data
                             and then Is_JSON_String (Text_Of (V)));
               begin
                  Result :=
                    (if Value.Operator = Compare_Is_String
                     then Says else not Says);
               end;

            when Compare_Is_Mapping | Compare_Is_Not_Mapping =>
               declare
                  V    : constant Held := Held_Of (Value.Left);
                  Says : constant Boolean :=
                    (V.Kind = Value_Data
                     and then Is_JSON_Mapping (Text_Of (V)))
                    or else V.Kind = Value_JSON;
               begin
                  Result :=
                    (if Value.Operator = Compare_Is_Mapping
                     then Says else not Says);
               end;

            when Compare_Is_Number | Compare_Is_Not_Number =>
               declare
                  V    : constant Held := Held_Of (Value.Left);
                  Says : constant Boolean :=
                    V.Kind = Value_Number
                    or else (V.Kind = Value_Data
                             and then Text_Of (V)'Length > 0
                             and then Text_Of (V) (Text_Of (V)'First)
                                      in '0' .. '9' | '-');
               begin
                  Result :=
                    (if Value.Operator = Compare_Is_Number
                     then Says else not Says);
               end;

            when Compare_Is_Sequence | Compare_Is_Not_Sequence =>
               declare
                  V    : constant Held := Held_Of (Value.Left);
                  Says : constant Boolean :=
                    V.Kind in Value_Text | Value_Data | Value_JSON
                              | Value_Tools | Value_List
                    or else (V.Kind = Value_Call and then V.Index = 0);
               begin
                  Result :=
                    (if Value.Operator = Compare_Is_Sequence
                     then Says else not Says);
               end;

            when Compare_Is_Undefined | Compare_Is_Not_Undefined =>
               Result :=
                 (if Value.Operator = Compare_Is_Undefined
                  then not Is_Defined (Value.Left)
                  else Is_Defined (Value.Left));

            when Compare_Is_Iterable | Compare_Is_Not_Iterable =>
               --  What can be walked: a list, a mapping, text -- which the
               --  language walks character by character -- the tools, a
               --  list of messages and a turn's calls.
               declare
                  V    : constant Held := Held_Of (Value.Left);
                  Says : constant Boolean :=
                    V.Kind in Value_Text | Value_Data | Value_JSON
                              | Value_Tools | Value_List
                    or else (V.Kind = Value_Call and then V.Index = 0);
               begin
                  Result :=
                    (if Value.Operator = Compare_Is_Iterable
                     then Says else not Says);
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

      --  Bind a loop's variable to its element, and its key where the
      --  loop walks a mapping.
      --  Bind a name to one span of a container's JSON: a string as its
      --  decoded text, anything else as the JSON where it lies.
      procedure Bind_Span
        (Where : Natural; Src : String; Value : Span; Base : Natural) is
      begin
         if Is_JSON_String (Src (Value.First .. Value.Last)) then
            Assign_Text (Where, Decoded (Src (Value.First .. Value.Last)));
         elsif Is_JSON_Number (Src (Value.First .. Value.Last)) then
            Assign_Text (Where, Src (Value.First .. Value.Last), Value_Number);
         elsif Src (Value.First .. Value.Last) in "true" | "false" | "null" then
            Store (Where, Read_Out (Src (Value.First .. Value.Last)));
         else
            Slots (Where) :=
              (Kind => Value_Data,
               Offset => Base + Value.First - Src'First,
               Length => Value.Last - Value.First + 1,
               Start => 1);
         end if;
      end Bind_Span;

      procedure Bind_Element (L : in out Loop_State) is
      begin
         case L.Kind is
            when Over_Elements | Over_Entries =>
               declare
                  Src    : constant String :=
                    Pool (L.Base + 1 .. L.Base + L.Base_Length);
                  Key, Value : Span;
                  Found  : Boolean;
                  Cursor : Natural := L.Cursor;
               begin
                  if L.Kind = Over_Elements then
                     Next_Element (Src, Cursor, Value, Found);
                     if Found and then L.Key /= 0
                       and then Is_JSON_List (Src (Value.First .. Value.Last))
                     then
                        --  Two names over a list of pairs take the pair
                        --  apart, as the language unpacks a tuple: what
                        --  dictsort answers is walked this way.
                        declare
                           Inner  : Natural := Value.First + 1;
                           First, Second : Span;
                           Got    : Boolean;
                        begin
                           Next_Element (Src, Inner, First, Got);
                           if Got then
                              Bind_Span (L.Var, Src, First, L.Base);
                              Next_Element (Src, Inner, Second, Got);
                              if Got then
                                 Bind_Span (L.Key, Src, Second, L.Base);
                              end if;
                           end if;
                        end;
                     elsif Found then
                        Bind_Span (L.Var, Src, Value, L.Base);
                     end if;
                  else
                     --  A mapping walked: the first name is the key, as
                     --  it is in the language whether or not a second
                     --  name is written for the value.
                     Next_Member (Src, Cursor, Key, Value, Found);
                     if Found then
                        Assign_Text
                          (L.Var, Decoded (Src (Key.First .. Key.Last)));
                        if L.Key /= 0 then
                           Bind_Span (L.Key, Src, Value, L.Base);
                        end if;
                     end if;
                  end if;
                  if Found then
                     L.Cursor := Cursor;
                  end if;
               end;
            when Over_Tools =>
               Slots (L.Var) :=
                 (Kind => Value_JSON, Start => L.Index, others => <>);
            when Over_Messages =>
               Slots (L.Var) :=
                 (Kind => Value_Message, Offset => 0, Length => 0,
                  Start => (if L.Reversed then L.To - L.Index + 1
                            else L.From + L.Index - 1));
            when Over_Calls =>
               Slots (L.Var) :=
                 (Kind => Value_Call, Offset => L.Message, Length => 0,
                  Start => L.Index);
            when others =>
               null;
         end case;
      end Bind_Element;

      --  Start walking whatever the operand is worth, or skip the loop.
      procedure Each_Begin (Step : Instruction) is
         V : constant Held := Held_Of (Item.Operands.all (Step.Value_At));
         L : Loop_State;
      begin
         L.Var := Step.Offset;
         L.Key := Step.Length;
         L.Index := 1;
         L.Reversed := Step.Reversed;

         case V.Kind is
            when Value_Data | Value_JSON =>
               declare
                  Src : constant String := JSON_Text (V);
               begin
                  if Is_JSON_List (Src) then
                     L.Kind := Over_Elements;
                  elsif Is_JSON_Mapping (Src) then
                     L.Kind := Over_Entries;
                  else
                     Position := Step.Target;
                     return;
                  end if;
                  L.Total := JSON_Length (Src);
                  if L.Total = 0 then
                     Position := Step.Target;
                     return;
                  end if;
                  --  The container's text, kept while the loop runs and
                  --  read element by element.
                  if Pool_Used + Src'Length > Pool'Length then
                     Refuse (Item.Names (L.Var).Offset,
                             Item.Names (L.Var).Length,
                             E.Template_Variables_Too_Large);
                     Position := Step.Target;
                     return;
                  end if;
                  L.Base := Pool_Used;
                  L.Base_Length := Src'Length;
                  Pool (Pool_Used + 1 .. Pool_Used + Src'Length) := Src;
                  Pool_Used := Pool_Used + Src'Length;
                  L.Cursor := L.Base + 2;
               end;
            when Value_Tools =>
               L.Kind := Over_Tools;
               L.Total := Tool_Count;
            when Value_List =>
               L.Kind := Over_Messages;
               L.From := V.Start;
               L.To := Count;
               L.Total := Integer'Max (Count - V.Start + 1, 0);
            when Value_Call =>
               if V.Index /= 0 then
                  Position := Step.Target;
                  return;
               end if;
               L.Kind := Over_Calls;
               L.Message := V.Start;
               L.Total := Length_Of (V);
            when others =>
               --  A name never assigned is refused here as it is in the
               --  output; a field a message has not got, or none, is an
               --  empty walk -- and so are the tools when none were
               --  offered, which is what a template that walks them
               --  unguarded means.
               declare
                  Source : Operand renames Item.Operands.all (Step.Value_At);
               begin
                  if V.Kind = Value_Undefined
                    and then Source.Count = 1
                    and then Source.Terms (1).Offset /= Item.Tools_Slot
                    and then Source.Terms (1).Kind = Term_Variable
                    and then Source.Terms (1).Path_Len = 0
                    and then not Source.Terms (1).Indexes
                    and then Source.Terms (1).Chained = 0
                    and then Source.Terms (1).Filtered = 0
                  then
                     Refuse (Item.Names (Source.Terms (1).Offset).Offset,
                             Item.Names (Source.Terms (1).Offset).Length,
                             E.Template_Unknown_Variable);
                  end if;
               end;
               Position := Step.Target;
               return;
         end case;

         if L.Total = 0 or else Loop_Depth >= Max_Loops then
            Position := Step.Target;
            return;
         end if;

         Push_Loop (L);
         Bind_Element (Loops (Loop_Depth));
         Position := Position + 1;
      end Each_Begin;

      --  Advance the innermost loop, or leave it.
      procedure Each_Next (Step : Instruction) is
      begin
         if Loop_Depth = 0 then
            Position := Position + 1;
            return;
         end if;

         declare
            L : Loop_State renames Loops (Loop_Depth);
         begin
            if L.Index < L.Total and then not Breaking then
               L.Index := L.Index + 1;
               Bind_Element (L);
               Position := Step.Target + 1;
            else
               Breaking := False;
               Slots (L.Var) := (Kind => Value_Undefined, others => <>);
               if L.Key /= 0 then
                  Slots (L.Key) := (Kind => Value_Undefined, others => <>);
               end if;
               if L.Kind in Over_Elements | Over_Entries
                 and then L.Base + L.Base_Length = Pool_Used
               then
                  Pool_Used := L.Base;
               end if;
               Pop_Loop;
               Position := Position + 1;
            end if;
         end;
      end Each_Next;

      procedure Execute is
      begin
         Iterations := Iterations + 1;
         if Iterations > Item.Step_Limit then
            Exhausted := True;
            Position := Item.Program_Used + 1;
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
                        if Step.Binds then
                           Bind_Message (Current);
                        end if;
                        Push_Loop ((Kind => Legacy_List, others => <>));
                        Position := Position + 1;
                     end if;
                  end;

               when Op_For_Next =>
                  if Current < Count and then not Breaking then
                     Current := Current + 1;
                     if Step.Binds then
                        Bind_Message (Current);
                     end if;
                     Position := Step.Target + 1;
                  else
                     Current := 0;
                     if Step.Binds then
                        Bind_Message (0);
                     end if;
                     Pop_Loop;
                     Breaking := False;
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

               when Op_Break =>
                  Breaking := True;
                  Position := Step.Target;

               when Op_Continue =>
                  Position := Step.Target;

               when Op_Set_Caller =>
                  Pending_Caller := Step.Offset;
                  Position := Position + 1;

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
                        --  Not a list of messages: one element of whatever
                        --  the name holds, a list read out of a schema or
                        --  the pieces of a cut.
                        Store (Step.Offset,
                               Element_At (Held_Of (Step.Target), Wanted));
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
                        Push_Loop ((Kind => Legacy_Calls, others => <>));
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
                     if Call_At < Asked and then not Breaking then
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
                        Pop_Loop;
                        Breaking := False;
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
                     Range_Start := Range_At;
                     Range_Stop :=
                       Number_Of (Value_Of (Item.Operands.all (Bounds + 1)));
                     Range_Step :=
                       Number_Of (Value_Of (Item.Operands.all (Bounds + 2)));

                     if Range_Step = 0 or else not Counting_On then
                        Position := Step.Target;
                     else
                        Assign_Text
                          (Range_Slot, Model_Runner.Text.Image (Range_At),
                           Value_Number);
                        Push_Loop ((Kind => Legacy_Range, others => <>));
                        Position := Position + 1;
                     end if;
                  end;

               when Op_Range_Next =>
                  Range_At := Range_At + Range_Step;
                  if Counting_On and then not Breaking then
                     Assign_Text
                       (Range_Slot, Model_Runner.Text.Image (Range_At),
                        Value_Number);
                     Position := Step.Target + 1;
                  else
                     Pop_Loop;
                     Breaking := False;
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
                  if Slots (Step.Target).Kind in Value_Text | Value_Number
                  then
                     Assign_Text
                       (Step.Offset,
                        Pool (Slots (Step.Target).Offset + 1
                              .. Slots (Step.Target).Offset
                                 + Slots (Step.Target).Length),
                        Slots (Step.Target).Kind);
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

               when Op_Capture_Begin =>
                  --  Nesting is bounded where the blocks are compiled, so
                  --  the stack cannot fill.
                  Capture_Depth := Capture_Depth + 1;
                  Captures (Capture_Depth) := Last;
                  Position := Position + 1;

               when Op_Capture_End =>
                  --  What was written since the block opened becomes the
                  --  name's value and leaves the output.
                  declare
                     Mark : constant Natural := Captures (Capture_Depth);
                  begin
                     Capture_Depth := Capture_Depth - 1;
                     Assign_Text
                       (Step.Offset,
                        Target (Target'First + Mark .. Target'First + Last - 1));
                     Last := Mark;
                  end;
                  Position := Position + 1;

               when Op_Return =>
                  --  The end of a macro's body. Inside a call it hands
                  --  back to Run_Macro; reached otherwise -- which the jump
                  --  over the body prevents -- it ends the program.
                  if Call_Depth > 0 then
                     Returned := True;
                  else
                     Position := Item.Program_Used + 1;
                  end if;

               when Op_Set_Value =>
                  Store (Step.Offset,
                         Held_Of (Item.Operands.all (Step.Value_At)));
                  Position := Position + 1;

               when Op_Each_Begin =>
                  Each_Begin (Step);

               when Op_Each_Next =>
                  Each_Next (Step);

               when Op_Unsupported =>
                  Refuse (Step.Offset, Step.Length,
                          E.Template_Unsupported_Construct);
                  Position := Position + 1;
            end case;
         end;
      end Execute;

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
      --  The tools, and none where none were offered: defined either
      --  way, as the reference implementation passes them -- tools=None
      --  -- so a template asking "tools is defined" gets the answer it
      --  was written against, and "if tools", "tools is none" and "tools
      --  is iterable" each say what they say there.
      if Item.Tools_Slot /= 0 then
         Slots (Item.Tools_Slot) :=
           (if Tool_Count > 0 then (Kind => Value_Tools, others => <>)
            else (Kind => Value_None, others => <>));
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

      --  A flat instruction list with jumps. Rendering recurses in one
      --  place only, a macro call, and that is bounded by the nesting
      --  depth; the iteration bound holds across the whole render, calls
      --  included.
      while Position <= Item.Program_Used loop
         Execute;

         if Exhausted then
            Last := 0;
            Status := E.Make (E.Template_Iteration_Limit);
            E.Add_Integer
              (Status, "limit", Long_Long_Integer (Item.Step_Limit));
            return;
         end if;

         if Refused then
            Last := 0;
            Status := E.Make (Refused_Why);
            if Refused_Why = E.Template_Variables_Too_Large then
               E.Add_Integer
                 (Status, "limit",
                  Long_Long_Integer (if Refused_Limit /= 0 then Refused_Limit
                                     else Pool'Length),
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
