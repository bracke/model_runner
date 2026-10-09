with Ada.Calendar.Formatting;
with Ada.Calendar.Time_Zones;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Exceptions;
with Ada.Strings.UTF_Encoding.Wide_Wide_Strings;
with Ada.Unchecked_Deallocation;
with Ada.Wide_Wide_Characters.Handling;
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
     (Block_For, Block_If, Block_Macro, Block_Set, Block_Filter, Block_Call,
      Block_With);

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
         --  same way, since there is nowhere else for them. Gemma has no tool
         --  tokens; it was taught to call a function by writing the call in
         --  Python, in a ```tool_code block, and to read its result from a
         --  ```tool_output one, so that is what the first user turn asks
         --  for, in the words Google gives for it: the functions as Python
         --  definitions with their docstrings, a parameter the schema does
         --  not require given a default of None. Asked for JSON in tags
         --  instead, a 4B wrote fenced calls of its own invention and the
         --  tools' answers with them. An assistant turn that called writes
         --  each call as Python in its block; a run of tool answers is
         --  folded into one user turn, a ```tool_output block each, Gemma
         --  having no tool role either. Tools.Read_Calls reads the calls in
         --  its Python_Code syntax and the call grammar holds them to it.
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
           & "```tool_output" & LF
           & "{{ message.content }}" & LF
           & "```" & LF
           & "{% if loop.last"
           & " or turns[loop.index0 + 1].role != 'tool' %}"
           & "<end_of_turn>" & LF
           & "{% endif %}"
           & "{% elif message.role == 'assistant' %}"
           & "<start_of_turn>model" & LF
           --  Walked as the model's own template walks a reply given as
           --  parts, the same way it walks a user's.
           & "{% if message.content is string %}"
           & "{{ message.content | trim }}"
           & "{% else %}"
           & "{% for item in message.content %}"
           & "{% if item['type'] == 'image' %}<start_of_image>"
           & "{% elif item['type'] == 'text' %}{{ item['text'] | trim }}"
           & "{% endif %}"
           & "{% endfor %}"
           & "{% endif %}"
           & "{% if message.tool_calls %}"
           & "{% for tool_call in message.tool_calls %}"
           --  A call given in the reference's shape, the name and the
           --  arguments under a function member, is read from there, as
           --  the models' own templates read one.
           & "{% if tool_call.function is defined %}"
           & "{% set tool_call = tool_call.function %}{% endif %}"
           --  Each call a block of its own, on a line of its own after
           --  what the turn said, its arguments as Python keywords: a
           --  string, a number, a list or a mapping as JSON writes it,
           --  which reads as the same Python, and a truth value or a null
           --  as Python spells them.
           & "{% if not loop.first or (message.content is string"
           & " and message.content | trim) +%}" & LF
           & "{% endif %}"
           & "```tool_code" & LF
           & "{{ tool_call.name }}("
           & "{% for key, value in tool_call.arguments.items() %}"
           & "{% if not loop.first %}, {% endif %}{{ key }}="
           & "{% if value is boolean %}{% if value %}True{% else %}False"
           & "{% endif %}{% elif value is none %}None"
           & "{% else %}{{ value | tojson }}{% endif %}"
           & "{% endfor %})" & LF
           & "```"
           & "{% endfor %}"
           & "{% endif %}"
           & "<end_of_turn>" & LF
           & "{% elif message.role != 'user' %}"
           --  A role the model never saw -- a second system turn, a
           --  developer's -- is refused in its own template's words
           --  rather than written as a turn it was not trained on.
           & "{{ raise_exception('Conversation roles must alternate "
           & "user/assistant/user/assistant/...') }}"
           & "{% else %}"
           & "<start_of_turn>{{ message.role }}" & LF
           & "{% if loop.first %}"
           & "{% if messages[0]['role'] == 'system' %}"
           & "{{ messages[0]['content'] }}" & LF & LF
           & "{% endif %}"
           & "{% if tools %}"
           & "At each turn, if you decide to invoke any of the function(s), "
           & "it should be wrapped with ```tool_code```. The python methods "
           & "described below are imported and available, you can only use "
           & "defined methods. The generated code should be readable and "
           & "efficient. The response to a method will be wrapped in "
           & "```tool_output``` use it to call more tools or generate a "
           & "helpful, friendly response. When using a ```tool_code``` "
           & "think step by step why and how it should be used." & LF & LF
           & "The following Python methods are available:" & LF & LF
           & "```python" & LF
           & "{% for tool in tools %}"
           & "{% if tool.function is defined %}"
           & "{% set tool = tool.function %}{% endif %}"
           & "def {{ tool.name }}("
           & "{% for name, schema in tool.parameters.properties.items() %}"
           & "{% if not loop.first %}, {% endif %}{{ name }}"
           & "{% if schema.type is defined %}: "
           & "{% if schema.type == 'string' %}str"
           & "{% elif schema.type == 'integer' %}int"
           & "{% elif schema.type == 'number' %}float"
           & "{% elif schema.type == 'boolean' %}bool"
           & "{% elif schema.type == 'array' %}list"
           & "{% else %}dict{% endif %}{% endif %}"
           & "{% if tool.parameters.required is not defined"
           & " or name not in tool.parameters.required %} = None{% endif %}"
           & "{% endfor %}) -> dict:" & LF
           & "    """"""{{ tool.description }}" & LF
           & "{% if tool.parameters.properties +%}" & LF
           & "    Args:" & LF
           & "{% for name, schema in tool.parameters.properties.items() %}"
           & "      {{ name }}: {{ schema.description | default('') }}" & LF
           & "{% endfor %}"
           & "{% endif %}"
           & "    """"""" & LF & LF
           & "{% endfor %}"
           & "```" & LF & LF
           & "{% endif %}"
           & "{% endif %}"
           --  Content given as parts is walked as the model's own template
           --  walks it: a picture is its marker, and words are trimmed.
           & "{% if message.content is string %}"
           & "{{ message.content | trim }}"
           & "{% else %}"
           & "{% for item in message.content %}"
           & "{% if item['type'] == 'image' %}<start_of_image>"
           & "{% elif item['type'] == 'text' %}{{ item['text'] | trim }}"
           & "{% endif %}"
           & "{% endfor %}"
           & "{% endif %}"
           & "<end_of_turn>" & LF
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
           & "{% for tool_call in message.tool_calls %}"
           --  A call given in the reference's shape, the name and the
           --  arguments under a function member, is read from there, as
           --  the models' own templates read one. +%} keeps the line
           --  break the model's own template writes before each call.
           & "{% if tool_call.function is defined %}"
           & "{% set tool_call = tool_call.function %}{% endif +%}"
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
           --  Joined with +, as the model's own template joins a reply to
           --  its markers, so that a reply given as parts is refused as
           --  that template refuses it.
           & "{{ content + '<|im_end|>' }}" & LF
           & "{% else %}"
           --  Any other turn under its own name, a second system turn
           --  or a developer's, as the model's own template writes them --
           --  joined with +, so that content given as parts is refused
           --  the way that template's author refuses it, with words
           --  added to a list.
           & "{{ '<|im_start|>' + message.role + '\n' + message.content"
           & " + '<|im_end|>' + '\n' }}"
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
           --  An answer given as parts is written as JSON, as the model's
           --  own template writes one.
           & "{% if message.content is string %}{{ message.content }}"
           & "{% else %}{{ message.content | tojson }}{% endif +%}" & LF
           & "</tool_response>"
           & "{% if loop.last"
           & " or turns[loop.index0 + 1].role != 'tool' %}"
           & "<|im_end|>" & LF
           & "{% endif %}"
           & "{% elif message.role == 'assistant' %}"
           --  A reply is its words when it is words and nothing when it is
           --  parts, as the model's own template reads one.
           & "{% if message.content is string %}"
           & "{% set spoken = message.content %}"
           & "{% else %}{% set spoken = '' %}{% endif %}"
           & "{% if '</think>' in spoken %}"
           & "{% set reasoning = spoken.split('</think>')[0]"
           & ".rstrip('\n').split('<think>')[-1].lstrip('\n') %}"
           & "{% set content = spoken.split('</think>')[-1]"
           & ".lstrip('\n') %}"
           & "{% else %}"
           & "{% set reasoning = '' %}"
           & "{% set content = spoken %}"
           & "{% endif %}"
           & "<|im_start|>assistant" & LF
           & "{% if loop.index0 > ns.last_query_index and reasoning %}"
           & "<think>" & LF & "{{ reasoning }}" & LF & "</think>" & LF & LF
           & "{% endif %}"
           & "{{ content }}"
           & "{% if message.tool_calls %}"
           & "{% for tool_call in message.tool_calls %}"
           --  A call given in the reference's shape, the name and the
           --  arguments under a function member, is read from there, as
           --  the models' own templates read one.
           & "{% if tool_call.function is defined %}"
           & "{% set tool_call = tool_call.function %}{% endif %}"
           & "{% if (loop.first and content) or not loop.first +%}"
           & LF
           & "{% endif %}"
           & "<function name=""{{ tool_call.name }}"">"
           & "{{ tool_call.arguments | params }}</function>"
           & "{% endfor %}"
           & "{% endif %}"
           & "<|im_end|>" & LF
           & "{% elif message.role == 'user' or message.role == 'system' %}"
           --  A user turn, or a system turn after the first, and no
           --  other: the model's own template writes nothing for a role
           --  it does not name -- and nothing for content given as parts,
           --  which it reads as words only when it is words.
           & "<|im_start|>{{ message.role }}" & LF
           & "{% if message.content is string %}{{ message.content }}"
           & "{% endif %}<|im_end|>" & LF
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
      elsif Name = Format_Name (Format_Functionary) then
         --  Functionary v3.2, carried because its own template calls a schema
         --  generator this engine does not run. Turns are Llama-3's; a system
         --  turn opens the prompt and, where tools are offered, carries the
         --  recipient-format instructions and each tool's signature as JSON.
         --  An assistant turn's words are its >>>all block and each call a
         --  >>>name block; a tool answer is its own tool turn. The generation
         --  prompt ends with >>> so the model writes the recipient at once,
         --  and the call it writes back is read in Recipient_JSON syntax.
         return
           "{{ bos_token }}"
           & "<|start_header_id|>system<|end_header_id|>" & LF & LF
           & "{% if messages[0]['role'] == 'system' %}"
           & "{{ messages[0]['content'] }}" & LF
           & "{% else %}"
           & "You are a helpful assistant." & LF
           & "{% endif %}"
           & "{% if tools %}"
           & "You are capable of executing available function(s) if required."
           & LF
           & "Only execute function(s) when absolutely necessary." & LF
           & "Use JSON for function arguments." & LF
           & "Respond with a recipient and its content, the recipient on a "
           & "line beginning >>> and the content on the lines after it; the "
           & "recipient all is what you say to the user, a function's name is "
           & "a call of it." & LF
           & "Available functions:" & LF
           & "{% for tool in tools +%}" & LF & "{{ tool | tojson }}"
           & "{% endfor +%}" & LF
           & "{% endif %}"
           & "<|eot_id|>"
           & "{% if messages[0]['role'] == 'system' %}"
           & "{% set turns = messages[1:] %}"
           & "{% else %}{% set turns = messages %}{% endif %}"
           & "{% for message in turns %}"
           & "{% if message.role == 'assistant' %}"
           & "<|start_header_id|>assistant<|end_header_id|>" & LF & LF
           & "{% if message.content is string and message.content %}"
           & ">>>all" & LF & "{{ message.content }}" & LF
           & "{% endif %}"
           & "{% if message.tool_calls %}"
           & "{% for tool_call in message.tool_calls %}"
           & "{% if tool_call.function is defined %}"
           & "{% set tool_call = tool_call.function %}{% endif %}"
           & ">>>" & "{{ tool_call.name }}" & LF
           & "{{ tool_call.arguments }}" & LF
           & "{% endfor %}"
           & "{% endif %}"
           & "<|eot_id|>"
           & "{% else %}"
           & "<|start_header_id|>{{ message.role }}<|end_header_id|>" & LF & LF
           & "{% if message.content is string %}{{ message.content }}"
           & "{% endif %}<|eot_id|>"
           & "{% endif %}"
           & "{% endfor %}"
           & "{% if add_generation_prompt %}"
           & "<|start_header_id|>assistant<|end_header_id|>" & LF & LF & ">>>"
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
      elsif Has (">>>all") then
         --  Functionary before Llama3: its template opens turns the Llama3
         --  way but writes tool calls in the recipient form, and it is the
         --  ">>>" recipient that tells the two apart.
         return Format_Name (Format_Functionary);
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
       then Model_Runner.Tools.Python_Code
       elsif Name = Format_Name (Format_Functionary)
       then Model_Runner.Tools.Recipient_JSON
       else Model_Runner.Tools.Tool_Call_JSON);

   --  Where a loop's filter begins: the " if " of "for x in list if test",
   --  at the list's own level and outside quotes, or zero where there is
   --  none.
   function Filter_At (Text : String) return Natural is
      Level : Natural := 0;
      Quote : Character := ' ';
   begin
      for At_Char in Text'Range loop
         declare
            C : constant Character := Text (At_Char);
         begin
            if Quote /= ' ' then
               if C = Quote then
                  Quote := ' ';
               end if;
            elsif C in ''' | '"' then
               Quote := C;
            elsif C in '(' | '[' | '{' then
               Level := Level + 1;
            elsif C in ')' | ']' | '}' then
               if Level > 0 then
                  Level := Level - 1;
               end if;
            elsif Level = 0 and then C = ' '
              and then At_Char + 3 <= Text'Last
              and then Text (At_Char + 1 .. At_Char + 3) = "if "
            then
               return At_Char + 1;
            end if;
         end;
      end loop;
      return 0;
   end Filter_At;

   --  Whether the bracket at Index opens a tuple: a comma at its own level
   --  before the bracket that shuts it, outside quotes. "()" is a tuple
   --  too; "(a)" and "(a + b)" are groups.
   function Is_Tuple_At (Text : String; Index : Positive) return Boolean is
      Level : Natural := 0;
      Quote : Character := ' ';
   begin
      if Index + 1 <= Text'Last and then Text (Index + 1) = ')' then
         return True;
      end if;
      for At_Char in Index + 1 .. Text'Last loop
         declare
            C : constant Character := Text (At_Char);
         begin
            if Quote /= ' ' then
               if C = Quote then
                  Quote := ' ';
               end if;
            elsif C in ''' | '"' then
               Quote := C;
            elsif C in '(' | '[' | '{' then
               Level := Level + 1;
            elsif C in ')' | ']' | '}' then
               exit when Level = 0;
               Level := Level - 1;
            elsif C = ',' and then Level = 0 then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Is_Tuple_At;

   procedure Compile
     (Item   : in out Compiled;
      Source : String;
      Bounds : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Status : out E.Error_Info)
   is separate;

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
        := null;
      Image_Marker          : String := "";
      Video_Marker          : String := "")
   is separate;

   -------------
   -- Opening --
   -------------

   function Opening
     (Item            : Compiled;
      Messages        : Conv.History;
      Beginning_Token : String;
      End_Token       : String;
      Rendered        : String;
      Thinking        : Thinking_Choice := Thinking_Unstated;
      Tools           : access constant Offered_Tools.Definitions := null;
      Image_Marker    : String := "";
      Video_Marker    : String := "") return Natural
   is
      --  Room for the rendering without the prompt, which is no longer
      --  than the one with it where the template is the usual shape, and
      --  for a little more where it is not -- and at least the room the
      --  names a template sets are given, which is sized by it: a buffer
      --  the rendering's length left a conversation's turns no room to be
      --  held in names. Pages never written cost nothing.
      Buffer : Text_Access :=
        new String
          (1 .. Natural'Max (Rendered'Length + 4096, Max_Variable_Bytes));
      Last   : Natural;
      Status : E.Error_Info;
      Shared : Natural := 0;
   begin
      Render
        (Item, Messages, Beginning_Token, End_Token, False, Buffer.all,
         Last, Status, Thinking, Tools, Image_Marker, Video_Marker);
      if E.Is_Error (Status) then
         Free_Text (Buffer);
         return 0;
      end if;
      while Shared < Last and then Shared < Rendered'Length
        and then Buffer (Shared + 1) = Rendered (Rendered'First + Shared)
      loop
         Shared := Shared + 1;
      end loop;
      Free_Text (Buffer);
      return Rendered'Length - Shared;
   end Opening;

end Model_Runner.Templates;
