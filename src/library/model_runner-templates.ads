private with Ada.Finalization;

with Model_Runner.Conversation;
with Model_Runner.Errors;
with Model_Runner.Limits;

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
--    {% for message in LIST %} ... {% endfor %}
--    {% if cond %} ... {% elif cond %} ... {% else %} ... {% endif %}
--    {% set name = value %}  value being a term expression, none, another
--                            name, or a list with a leading slice removed
--    {%- ... -%} and {{- ... -}}   whitespace control on either side
--
--  Terms usable in output and in comparisons
--
--    'literal'  "literal"      with \n, \t, \r, \\ and \' escapes
--    123                       digits, as the text of the number
--    true  false  none
--    bos_token  eos_token
--    message['role']    message.role
--    message['content'] message.content
--    messages[0]['role']       and its like, relative to what the name
--                              messages refers to at that point
--    add_generation_prompt
--    loop.first  loop.last  loop.index0  loop.index
--    any name the template has assigned
--    | trim  and  | length
--
--  Conditions are an or-list of and-lists of clauses, each clause optionally
--  negated by 'not', optionally parenthesised, and optionally comparing two
--  terms with '==' or '!=' or testing one with 'is defined', 'is none' or
--  "'field' in message", any of which may be negated with 'is not'.
--
--  Structural constructs outside the subset -- macro, include, import,
--  extends, filter blocks -- are rejected at compile time with
--  Template_Unsupported_Construct, because a program whose shape cannot be
--  read cannot be reasoned about at all.
--
--  Expressions outside the subset -- function calls, JSON encoding, date
--  formatting, arithmetic, indexing into anything but messages -- compile to
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
   type Chat_Format is (Format_Llama3, Format_ChatML);

   --  The name a caller asks for a format by.
   --
   --  @param Item Format to name.
   --  @return Lower-case identifier such as "llama3".
   function Format_Name (Item : Chat_Format) return String
   is (case Item is
         when Format_Llama3 => "llama3",
         when Format_ChatML => "chatml");

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

   --  Render a conversation.
   --
   --  @param Item Compiled template.
   --  @param Messages Conversation to render.
   --  @param Beginning_Token Text substituted for bos_token.
   --  @param End_Token Text substituted for eos_token.
   --  @param Add_Generation_Prompt Value of add_generation_prompt.
   --  @param Target Buffer receiving the rendered prompt.
   --  @param Last Number of bytes written; 0 on failure.
   --  @param Status Success, Template_Output_Too_Large,
   --    Template_Iteration_Limit or Template_Missing.
   procedure Render
     (Item                  : Compiled;
      Messages              : Model_Runner.Conversation.History;
      Beginning_Token       : String;
      End_Token             : String;
      Add_Generation_Prompt : Boolean;
      Target                : out String;
      Last                  : out Natural;
      Status                : out Model_Runner.Errors.Error_Info);

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
   type Filter_Kind is (Filter_None, Filter_Trim, Filter_Length);

   type Term is record
      Kind   : Term_Kind := Term_Literal;
      Offset : Natural := 0;
      Length : Natural := 0;
      Filter : Filter_Kind := Filter_None;

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
      Compare_In_Message);

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

      --  Taken from the bounds this was compiled with, so that rendering
      --  needs no bounds of its own.
      Step_Limit   : Positive := Max_Iterations;
   end record;

   overriding procedure Finalize (Item : in out Compiled);

end Model_Runner.Templates;
