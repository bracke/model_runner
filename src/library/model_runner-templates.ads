private with Ada.Finalization;

with Model_Runner.Conversation;
with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Tools;

--  Bounded chat-template rendering.
--
--  An embedded chat template is untrusted data. This engine implements a small
--  allowlisted subset and rejects everything else at compile time, before any
--  generation happens. It is not a Jinja implementation and does not try to
--  become one: a template that needs a construct outside the subset is
--  reported as unsupported rather than approximated.
--
--  Supported constructs
--
--    literal text
--    {{ terms }}             terms joined by '+', see below
--    {# comment #}
--    {% for message in LIST %} ... {% endfor %}   the variable may be
--                            named anything, and what the name decides is
--                            whether it binds: message is the name a turn's
--                            fields are read through, so a loop calling its
--                            variable that binds each turn to it and a loop
--                            calling it something else walks the same list
--                            and leaves the name alone. A template that
--                            walks the conversation backwards writes the
--                            second and says which turn it means itself
--    {% if cond %} ... {% elif cond %} ... {% else %} ... {% endif %}
--    {% set name = value %}  value being a term expression, none, another
--                            name, a list with a leading slice removed, one
--                            message of a list, a namespace, or a choice
--                            written on one line: A if C else B, which a
--                            template writes where a turn may not carry the
--                            field it is after
--    {% for name in range(a, b, c) %} ... {% endfor %}   counting rather
--                            than walking a list; a, b and c are term
--                            expressions and c may count down
--    {% for name in tools %} ... {% endfor %}   walking the tools a caller
--                            offered, each of which is a value with no text
--                            of its own: it is written with | tojson and
--                            refused anywhere else
--    {% for tool_call in message.tool_calls %} ... {% endfor %}   walking
--                            the calls one turn asked for. The variable is
--                            named tool_call for the reason the list loop's
--                            is named message: the fields this engine can
--                            read from one are a call's fields
--    {%- ... -%} and {{- ... -}}   whitespace control on either side, and
--                            {%+ ... %} to keep the line a tag stands on
--
--  Whitespace around a block. A tag is written on a line of its own to be
--  read, and the line it stands on is the template's own shape rather than
--  text the model was trained to see. So the spaces and tabs between the
--  start of a line and a block tag are taken off, and the line break that
--  ends a block tag is taken off with it -- neither where something other
--  than whitespace shares that line, and neither for {{ an expression }},
--  which stands where its text is wanted. That is what the implementation
--  these templates are written for does with trim_blocks and lstrip_blocks,
--  which is how every template shipped in a model file was authored; a
--  template that means to keep its indentation says so with {%+, and one
--  that means to take more says so with {%- and -%} as before.
--
--  Terms usable in output and in comparisons
--
--    'literal'  "literal"      with \n, \t, \r, \\ and \' escapes
--    123                       digits, as the text of the number
--    true  false  none
--    bos_token  eos_token
--    message['role']    message.role
--    message['content'] message.content
--    message.tool_calls        whether this turn asked for tools, which is
--                              a question and not text: a template asks it
--                              in a condition and walks the answer
--    tool_call.name  tool_call.arguments   the call the loop above binds
--    messages[0]['role']       and its like, relative to what the name
--                              messages refers to at that point
--    add_generation_prompt
--    loop.first  loop.last  loop.index0  loop.index
--    any name the template has assigned, including a namespace's fields
--    messages[TERM]['role']  and  messages[TERM].role, the position being
--                            worked out rather than written
--    | trim  and  | length, the second answering a list's length as well as
--                            a text's
--    | tojson, which writes a tool as JSON and any text as a JSON string
--    .strip(S)  .lstrip(S)  .rstrip(S), the argument optional
--    .split(S)[0]  and  .split(S)[-1], which is how a template takes a
--                            reply apart at the marker its reasoning is in;
--                            up to four of these may follow one another.
--                            Which end is wanted may be said by a filter
--                            instead -- .split(S)|first and .split(S)|last
--                            are the same two questions -- and a cut that
--                            says neither refuses where it is read, because
--                            what it answers with is a list
--    TEXT[a:b]  TEXT[a:]  TEXT[:b]   a cut at a position rather than at a
--                            marker, either end optional and either counted
--                            from the end where it is negative, as the
--                            language counts one. A template writes the
--                            pair of them to ask whether a turn begins and
--                            ends with the markers a tool's answer is
--                            wrapped in
--    ( ... )                 brackets round part of a sum, which is how a
--                            template counts back from the end of a
--                            conversation: (messages|length - 1) -
--                            loop.index0. Brackets round a single value are
--                            that value, and what is written after them
--                            applies to it
--
--  Conditions are an or-list of and-lists of clauses, each clause optionally
--  negated by 'not', optionally parenthesised, and optionally comparing two
--  terms with '==', '!=', '<', '<=', '>' or '>=' -- the four orderings
--  reading both sides as whole numbers -- or testing one with 'is defined',
--  'is none', 'is true', 'is false' or 'is string', or asking whether text
--  occurs in text with "'x' in name" or whether a message carries a field
--  with "'field' in message". Any of them may be negated with 'is not', and
--  'in' with 'not in'.
--
--  A bare operand is a condition too, and is true when it holds something
--  other than nothing: the empty string, none and a name never assigned are
--  all false. A name the template never assigned is nothing when a condition
--  asks about it -- which is what "if tools" is for -- and an error when the
--  output asks for it, because printing the empty string where the template
--  meant text says nothing about the mistake.
--
--  Terms in an operand join with '+', which runs their text together, or
--  with '-', which reads both sides as whole numbers and subtracts. An
--  operand holding a subtraction is a number and answers as one, and so
--  does one whose every term is a number by construction -- a bare number,
--  a loop counter, a length. It answers the same whether it is assigned,
--  compared or printed: a template that works a position out in a set and
--  prints the same expression elsewhere means the same thing in both
--  places.
--
--  Structural constructs outside the subset -- macro, include, import,
--  extends, filter blocks -- are rejected at compile time with
--  Template_Unsupported_Construct, because a program whose shape cannot be
--  read cannot be reasoned about at all.
--
--  Tools. A caller may offer the model tools, and a template that reads
--  them writes their definitions into the prompt itself. What this engine
--  gives such a template is the name tools -- false when nothing was
--  offered, which is exactly what "if tools" asks -- a loop over it, and
--  the tojson filter that writes one out.
--
--  And what the model asks for back. A turn may carry tool calls beside its
--  text, which is what message.tool_calls asks about and what the loop over
--  it walks; each call answers to tool_call.name and tool_call.arguments.
--  A call kept as the text the model wrote would reach the next turn too --
--  it is still in the reply -- but it would reach it in the model's own
--  spelling rather than in the one the template writes, and the two are not
--  the same bytes. A template's own branch is the only thing that knows
--  which they should be.
--
--  Expressions outside the subset -- function calls, date formatting,
--  arithmetic, indexing into anything but messages -- compile to
--  an instruction that refuses when it is reached. Templates shipped with
--  current models describe tool calling in branches a conversation of plain
--  messages never enters, and refusing the template for a branch nobody takes
--  refuses the model. Refusing at the point of use refuses only what was
--  actually asked for; nothing is approximated and nothing is guessed,
--  because reaching one of these ends the render with
--  Template_Unsupported_Construct naming the construct.
--
--  The engine cannot open a file, read the environment, start a process,
--  reach the network or load a library, because it contains no operation that
--  does any of those things.
--
--  Bounds. Template size, instruction count, nesting depth, loop iterations
--  and output size are all bounded. Rendering cannot recurse: the compiled
--  form is a flat instruction list with jumps.
--
--  Task safety: a Compiled template is immutable after Compile and may be
--  rendered concurrently.
package Model_Runner.Templates is

   --  Largest number of instructions a template may compile to.
   Max_Instructions : constant := 4096;

   --  Largest nesting depth of for and if blocks.
   Max_Depth : constant := 16;

   --  Largest number of terms in one output expression or comparison side.
   Max_Terms : constant := 32;

   --  Largest number of distinct names a template may read or assign.
   Max_Variables : constant := 32;

   --  Largest total text a template's variables may hold during one render.
   Max_Variable_Bytes : constant := 65_536;

   --  Largest number of instruction steps one render may perform, across all
   --  loops. Bounds rendering time independently of the message count.
   --
   --  This is a termination condition, not a margin. The message loop nested
   --  inside itself does not finish on its own: raising this bound to two
   --  thousand million during testing produced two thousand million steps and
   --  a render still in progress. A template arriving in a model file is not
   --  trusted to terminate, so rendering stops counting rather than waiting.
   --  The default step bound. A caller changes it through Model_Limits, and
   --  a compiled template carries whatever it was compiled with.
   Max_Iterations : constant := 100_000;

   --  A compiled template. Release with Close, which is idempotent.
   type Compiled is tagged limited private;
   --  A chat format this build carries, by name.
   --
   --  Some models ship a template that this engine will not compile: it
   --  assigns variables, slices lists, calls functions and formats dates,
   --  most of it to describe tool calling, and interpreting all of that on
   --  text taken from a model file is a larger and more exposed thing than
   --  formatting a conversation. The reference implementation answers the
   --  same problem the same way, by carrying the well-known formats itself.
   --
   --  These are written in the subset this engine already compiles, so they
   --  are ordinary templates and not a second mechanism. A caller asks for
   --  one by name; nothing chooses one on a model's behalf, because a chat
   --  format applied to the wrong model is wrong in a way the output does
   --  not show.
   --
   --  @param Name Format name, such as "llama3" or "chatml".
   --  @return Template source, or the empty string when the name is unknown.
   function Built_In (Name : String) return String;

   --  The chat formats this build carries, in the order they are offered.
   --
   --  An enumeration rather than a list written into each place that needs
   --  one: the help text, the name matching and the tests all read from
   --  here, so none of them can offer a format that is not carried or miss
   --  one that is. The backends are named the same way for the same reason.
   type Chat_Format is (Format_Llama3, Format_ChatML, Format_Gemma,
                        Format_Phi3, Format_Qwen3_Coder);

   --  The name a caller asks for a format by.
   --
   --  @param Item Format to name.
   --  @return Lower-case identifier such as "llama3".
   function Format_Name (Item : Chat_Format) return String
   is (case Item is
         when Format_Llama3      => "llama3",
         when Format_ChatML      => "chatml",
         when Format_Gemma       => "gemma",
         when Format_Phi3        => "phi3",
         when Format_Qwen3_Coder => "qwen3-coder");

   --  Compile and validate a template.
   --
   --  @param Item Template to fill in; released first.
   --  @param Source Template text from model metadata.
   --  @param Bounds Model limits that bound the template size.
   --  @param Status Success, Template_Too_Large, Template_Syntax_Error,
   --    Template_Unsupported_Construct, Template_Unknown_Variable,
   --    Template_Nesting_Too_Deep or Template_Unbalanced_Block.
   procedure Compile
     (Item   : in out Compiled;
      Source : String;
      Bounds : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release a compiled template.
   --
   --  @param Item Template to release.
   procedure Close (Item : in out Compiled);

   --  Report whether a template compiled successfully.
   --
   --  @param Item Template to inspect.
   --  @return True when Compile succeeded.
   function Is_Compiled (Item : Compiled) return Boolean;

   --  Whether the caller has asked a model that reasons before it answers
   --  to do so, and the third answer: nothing at all.
   --
   --  A template asks after this by name, and asks first whether the name
   --  was given a value: a model whose caller says nothing is left to do
   --  what it was trained to do, and a model told not to reason is given the
   --  empty reasoning block its template writes for that. The three are
   --  different and a boolean cannot hold them.
   type Thinking_Choice is (Thinking_Unstated, Thinking_On, Thinking_Off);

   --  Render a conversation.
   --
   --  @param Item Compiled template.
   --  @param Messages Conversation to render.
   --  @param Beginning_Token Text substituted for bos_token.
   --  @param End_Token Text substituted for eos_token.
   --  @param Add_Generation_Prompt Value of add_generation_prompt.
   --  @param Thinking Value of enable_thinking, or that the caller said
   --    nothing about it.
   --  @param Target Buffer receiving the rendered prompt.
   --  @param Last Number of bytes written; 0 on failure.
   --  @param Status Success, Template_Output_Too_Large,
   --    Template_Iteration_Limit or Template_Missing.
   --  @param Tools The tools the caller offers, or null when there are
   --    none. A template that never mentions them renders the same either
   --    way, which is why a caller with tools asks Reads_Tools first rather
   --    than finding out from a prompt that says nothing about them.
   procedure Render
     (Item                  : Compiled;
      Messages              : Model_Runner.Conversation.History;
      Beginning_Token       : String;
      End_Token             : String;
      Add_Generation_Prompt : Boolean;
      Target                : out String;
      Last                  : out Natural;
      Status                : out Model_Runner.Errors.Error_Info;
      Thinking              : Thinking_Choice := Thinking_Unstated;
      Tools                 : access constant Model_Runner.Tools.Definitions
        := null);

   --  Report whether a template reads the tools a caller may offer.
   --
   --  @param Item Compiled template.
   --  @return True when the template mentions the name tools.
   function Reads_Tools (Item : Compiled) return Boolean;

private

   --  Where the value of a term comes from.
   type Term_Kind is
     (Term_Literal,
      Term_Beginning_Token,
      Term_End_Token,
      Term_Message_Role,
      Term_Message_Content,
      Term_Generation_Prompt,
      Term_Loop_First,
      Term_Loop_Last,
      Term_Loop_Index_Zero,
      Term_Loop_Index_One,

      --  The calls one turn asked for: whether there are any, and the two
      --  fields one of them has. The first is a question rather than text
      --  -- a template writes "if message.tool_calls" to find out whether
      --  the turn called anything -- and the other two are read from
      --  whichever call the loop over them has bound.
      Term_Message_Calls,
      Term_Call_Name,
      Term_Call_Arguments,

      --  A named message rather than the one being looped over:
      --  messages[0]['role'] and its like. Offset carries the index, counted
      --  from zero as the template writes it, relative to whatever the name
      --  messages refers to at that point.
      Term_Indexed_Role,
      Term_Indexed_Content,

      --  A name the template assigns to, or one it is given. Offset carries
      --  the position in the variable table.
      Term_Variable,

      Term_True,
      Term_False,
      Term_None,

      --  Something this engine cannot evaluate, carried through compilation
      --  so that a template is refused for what it does rather than for what
      --  it contains. Offset and Length name the construct, for the error
      --  raised if rendering ever reaches it.
      --
      --  Templates arriving in model files describe tool calling, date
      --  formatting and JSON encoding in branches that a conversation of
      --  plain messages never enters. Refusing the whole template at compile
      --  time for those branches refuses the template outright; refusing at
      --  the point of use refuses only what is actually asked for, and still
      --  cannot answer wrongly, because reaching one is an error and not a
      --  guess.
      Term_Unsupported);

   --  The filters this engine applies. Any other filter makes the term
   --  unsupported rather than the template unusable.
   type Filter_Kind is
     (Filter_None, Filter_Trim, Filter_Length,

      --  Write the value as JSON. A tool has no text of its own and this is
      --  the only way a template may write one; text has text, and what
      --  this makes of it is a quoted JSON string.
      Filter_JSON);

   --  What a template does to a piece of text after it has it: take
   --  whitespace off one end or both, or cut it at a marker and keep one
   --  side. A model whose replies carry their reasoning in a marked block
   --  writes its template this way, and there is no reading such a reply
   --  back into a conversation without it.
   type Method_Kind is
     (Method_None,
      Method_Strip,
      Method_Left_Strip,
      Method_Right_Strip,
      Method_Split_First,
      Method_Split_Last,

      --  A cut whose side has not been said yet: text.split(marker) with
      --  neither [0] nor [-1] after it. The language answers a list there,
      --  and the only thing a template does with that list is take one end
      --  of it with a filter -- which is what turns this into one of the
      --  two above. Left as it is, it refuses where it is read, because a
      --  list is not something this engine has a spelling for.
      Method_Split_Whole,

      --  A cut at a position rather than at a marker: text[n:] keeps what
      --  is from there on and text[:n] what is before it. A template writes
      --  the pair of them to ask whether a turn begins and ends with the
      --  markers a tool's answer is wrapped in, which is a question about
      --  the two ends of a text and not about anything in it. The position
      --  is counted as the language counts one: from the end where it is
      --  negative, and no further than the text goes either way.
      Method_Cut_From,
      Method_Cut_To);

   --  One method and where its one argument was kept: the characters to
   --  take off, or the marker to cut at.
   type Method_Step is record
      Kind : Method_Kind := Method_None;
      At_Operand : Natural := 0;
   end record;

   --  How many methods may follow one another. Four is what the template
   --  that prompted them writes: cut at the closing marker, trim, cut at the
   --  opening one, trim again.
   Max_Methods : constant := 4;

   type Method_Chain is array (1 .. Max_Methods) of Method_Step;

   --  How a term joins the one before it inside an operand. Plus is what
   --  Jinja's '+' does to two strings, which is to run them together;
   --  Minus reads both sides as whole numbers and subtracts, which is what
   --  a template does to turn a length into a last index.
   type Join_Kind is (Join_Plus, Join_Minus);

   type Term is record
      Kind   : Term_Kind := Term_Literal;
      Offset : Natural := 0;
      Length : Natural := 0;
      Filter : Filter_Kind := Filter_None;
      Join   : Join_Kind := Join_Plus;

      --  Whether this term is a number by construction rather than by what
      --  it happens to hold: a bare number, a loop counter, a length. What
      --  it decides is what '+' means between two of them -- the language
      --  this is written in adds numbers and runs text together, and a
      --  template asking for messages[loop.index0 + 1] means the message
      --  after this one and not the one at position "01".
      Numeric : Boolean := False;

      --  Where the index of an indexed term was kept, for the terms whose
      --  index is worked out rather than written: messages[loop.index0 - 1]
      --  and its like. Zero where Offset holds the index as the template
      --  wrote it.
      Index_At : Natural := 0;

      --  What is done to the text once it has been read, in the order it is
      --  written. A template that cuts a reply at its reasoning marker and
      --  then trims what is left writes four of these in a row, so they are
      --  a chain rather than one.
      Methods : Method_Chain := [others => <>];
      Chained : Natural := 0;

      --  What an unsupported term is unsupported for. A filter and a name
      --  are different things to have got wrong, and the reader can act on
      --  the difference.
      Why    : Model_Runner.Errors.Error_Code :=
        Model_Runner.Errors.Template_Unsupported_Construct;
   end record;

   type Term_Array is array (1 .. Max_Terms) of Term;

   --  One side of a comparison, or the whole clause when there is no operator.
   type Operand is record
      Terms : Term_Array := [others => <>];
      Count : Natural := 0;
   end record;

   type Comparison_Kind is
     (Compare_None,
      Compare_Equal,
      Compare_Not_Equal,

      --  Jinja's "is" tests. Only the two this engine can answer are here;
      --  every other test makes the clause unsupported.
      Compare_Defined,
      Compare_Not_Defined,
      Compare_Is_None,
      Compare_Is_Not_None,

      --  'name' in message: whether a message carries that field.
      Compare_In_Message,

      --  'text' in EXPRESSION: whether the left side occurs in the right.
      --  A different question from the one above and asked with the same
      --  word, which is why the two are told apart by what follows 'in'
      --  rather than by the word itself.
      Compare_In_Text,
      Compare_Not_In_Text,

      --  Numeric order. Both sides are read as whole numbers, and a side
      --  that is not one makes the clause false rather than an error: a
      --  template comparing a name it never assigned is asking about
      --  nothing, and nothing is not greater than anything.
      Compare_Less,
      Compare_Less_Or_Equal,
      Compare_Greater,
      Compare_Greater_Or_Equal,

      --  'is true', 'is false' and 'is string', which templates use to tell
      --  a flag that was set to false from one that was never set at all.
      Compare_Is_True,
      Compare_Is_Not_True,
      Compare_Is_False,
      Compare_Is_Not_False,
      Compare_Is_String,
      Compare_Is_Not_String);

   type Clause is record
      Negated : Boolean := False;
      Left    : Operand;
      Operator : Comparison_Kind := Compare_None;
      Right   : Operand;

      --  A parenthesised condition, held in the same table as the condition
      --  this clause belongs to. Zero when the clause is a plain comparison.
      Sub_At  : Natural := 0;
   end record;

   Max_Clauses : constant := 8;

   type Clause_Array is array (1 .. Max_Clauses) of Clause;

   --  Conjunctions joined by 'or'. Each conjunction is a run of clauses joined
   --  by 'and', which is the tighter operator.
   type Conjunction is record
      First : Natural := 0;
      Count : Natural := 0;
   end record;

   Max_Conjunctions : constant := 4;

   type Conjunction_Array is array (1 .. Max_Conjunctions) of Conjunction;

   type Condition is record
      Clauses     : Clause_Array := [others => <>];
      Clause_Used : Natural := 0;
      Groups      : Conjunction_Array := [others => <>];
      Group_Used  : Natural := 0;
   end record;

   type Opcode is
     (Op_Text,          --  emit a literal slice
      Op_Output,        --  emit an evaluated operand
      Op_For_Begin,     --  start iterating the list named by Offset
      Op_For_Next,      --  advance, jumping back while more remain
      Op_Jump_If_False, --  skip a branch
      Op_Jump,          --  unconditional jump
      Op_Set_Text,      --  assign an evaluated operand to a variable
      Op_Set_None,      --  assign none
      Op_Set_Copy,      --  assign another variable's value, whatever it is
      Op_Set_Slice,     --  assign a list with its first Length entries gone

      --  Iterate over whole numbers rather than over messages. Value_At
      --  names the first of three consecutive operands -- where the count
      --  starts, where it stops, and what it steps by -- and Offset names
      --  the variable each number is written to. A template uses one to walk
      --  the conversation backwards, which no list of messages can express.
      Op_Range_Begin,
      Op_Range_Next,

      --  Bind a name to one message of a list, which is what a template does
      --  when it walks the conversation by index rather than by loop.
      Op_Set_Message,

      --  Walk the tools a caller offered, binding each to a name. A loop of
      --  its own rather than the list loop with another list in it: what it
      --  binds is not a message and has no role and no content, and the
      --  fields a message has are the fields the list loop can read.
      Op_Tool_Begin,
      Op_Tool_Next,

      --  Walk the calls the bound message asked for. A third loop for the
      --  third thing there is to walk, and for the same reason as the
      --  second: a call is not a message and not a tool, and what can be
      --  read from one is neither's fields.
      Op_Call_Begin,
      Op_Call_Next,

      Op_Unsupported);  --  refuse, naming the construct, if ever reached

   --  An instruction names its operand and its condition rather than
   --  carrying them.
   --
   --  A condition is six kilobytes -- eight clauses of two thirty-two term
   --  operands -- and an operand is four hundred bytes, while an instruction
   --  needs neither unless it is a jump or an output. Carried inline, the
   --  fixed program of four thousand instructions came to twenty-six
   --  megabytes, allocated and initialised on every compile. Held to one
   --  side and pointed at, the program is a hundred kilobytes and the side
   --  tables are as long as the template actually needs.
   type Instruction is record
      Op      : Opcode := Op_Text;
      Offset  : Natural := 0;
      Length  : Natural := 0;
      Target  : Natural := 0;

      --  Positions in the compiled template's operand and condition tables,
      --  or zero when this instruction has none.
      Value_At : Natural := 0;
      Test_At  : Natural := 0;

      --  Whether a list loop binds the name a message goes by. A loop
      --  written for message in messages does; one that calls its variable
      --  something else walks the same list and binds nothing, because the
      --  name it binds is not one this engine reads fields from and the
      --  name message goes on meaning whatever it meant outside the loop.
      Binds    : Boolean := True;
   end record;

   type Instruction_Array is array (1 .. Max_Instructions) of Instruction;

   type Operand_Array is array (Positive range <>) of Operand;
   type Operand_Array_Access is access Operand_Array;

   type Condition_Array is array (Positive range <>) of Condition;
   type Condition_Array_Access is access Condition_Array;
   type Instruction_Access is access Instruction_Array;

   type Text_Access is access String;

   --  A name the template uses, as a slice of the compiled source pool. The
   --  first entry is always messages, so that a template which never assigns
   --  anything still has a list to iterate.
   type Variable_Name is record
      Offset : Natural := 0;
      Length : Natural := 0;
   end record;

   type Variable_Name_Array is array (1 .. Max_Variables) of Variable_Name;

   type Compiled is limited new Ada.Finalization.Limited_Controlled with record
      Ready        : Boolean := False;
      Program      : Instruction_Access := null;
      Program_Used : Natural := 0;
      Source       : Text_Access := null;
      Source_Used  : Natural := 0;

      --  Grown as the template needs them, rather than sized for the largest
      --  program the engine will accept.
      Operands      : Operand_Array_Access := null;
      Operand_Used  : Natural := 0;
      Conditions    : Condition_Array_Access := null;
      Condition_Used : Natural := 0;

      Names     : Variable_Name_Array := [others => <>];
      Name_Used : Natural := 0;

      --  Where the name a reasoning model's template asks after lives, or
      --  zero when the template never mentions it. Made when the template
      --  reads it rather than up front, so a template that says nothing
      --  about reasoning spends no slot on it.
      Thinking_Slot : Natural := 0;

      --  And where the name the tools arrive under lives. Zero says the
      --  template never asks about tools, which is what tells a caller with
      --  tools that this model has nowhere to put them.
      Tools_Slot : Natural := 0;

      --  And where the name one tool call goes by lives, or zero when the
      --  template walks no calls. The name is fixed for the reason the
      --  list loop's is: the fields readable from what it binds are a
      --  call's fields, so the loop that binds it is the loop that names it.
      Call_Slot : Natural := 0;

      --  Where the name message lives. A template binds it two ways -- as a
      --  loop's variable and by assignment -- and both are the same name, so
      --  message.role reads whichever binding is in force.
      Message_Slot : Natural := 0;

      --  Taken from the bounds this was compiled with, so that rendering
      --  needs no bounds of its own.
      Step_Limit   : Positive := Max_Iterations;
   end record;

   overriding procedure Finalize (Item : in out Compiled);

end Model_Runner.Templates;
